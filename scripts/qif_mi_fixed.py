#!/usr/bin/env python3
# qif_mi_fixed.py
# Bias-corrected QIF/MI re-estimation for the rbmm / rbmm_qgsp SCA pipeline.
#
# Inputs  (one row per trace, both files must align line-by-line):
#   --proxy   power_proxy_<design>_N<N>.npy   shape = (T,) float64
#                                             one scalar power-proxy per trace
#                                             (e.g. sum of toggle counts in the
#                                             leakage window for that trace)
#   --labels  labels_<design>_N<N>.npy        shape = (T,) int
#                                             HW(A*B mod 2^N) or HW(B), etc.
#
# Output:
#   prints I_plug, I_MM, I_KSG  (all in bits) with 95% bootstrap CI
#   appends a row to security_summary_fixed.csv
#
# Usage:
#   python qif_mi_fixed.py --proxy power_proxy_baseline_N256.npy \
#                          --labels labels_baseline_N256.npy    \
#                          --design baseline --N 256
#
# Dependencies: numpy, scipy, scikit-learn
#   pip install numpy scipy scikit-learn

import argparse, os, csv, math
import numpy as np
from scipy.special import digamma
from sklearn.neighbors import NearestNeighbors, KDTree

# ----------------------------------------------------------------------
# 1. Plug-in MI on a 2D histogram (this is what your current pipeline does)
# ----------------------------------------------------------------------
def mi_plugin_bits(labels, proxy, n_bins_y=64):
    """Histogram MI between discrete labels and a continuous proxy."""
    # bin the continuous proxy with equal-frequency bins (more stable than
    # equal-width when the equaliser stretches the range)
    qs = np.quantile(proxy, np.linspace(0, 1, n_bins_y + 1))
    qs[0]  -= 1e-9
    qs[-1] += 1e-9
    y_bin = np.digitize(proxy, qs[1:-1])

    x_vals = np.unique(labels)
    joint = np.zeros((len(x_vals), n_bins_y), dtype=np.float64)
    for i, xv in enumerate(x_vals):
        m = (labels == xv)
        for b in range(n_bins_y):
            joint[i, b] = np.sum(m & (y_bin == b))
    N = joint.sum()
    p_xy = joint / N
    p_x  = p_xy.sum(axis=1, keepdims=True)
    p_y  = p_xy.sum(axis=0, keepdims=True)
    with np.errstate(divide='ignore', invalid='ignore'):
        ratio = np.where(p_xy > 0, p_xy / (p_x * p_y), 1.0)
        mi = np.sum(p_xy * np.log2(ratio))
    # number of effectively populated bins
    Bx = np.sum(p_x  > 0)
    By = np.sum(p_y  > 0)
    Bxy = np.sum(p_xy > 0)
    return float(mi), int(Bx), int(By), int(Bxy), int(N)

# ----------------------------------------------------------------------
# 2. Miller-Madow correction
#    I_MM = I_plug - (B_xy - B_x - B_y + 1) / (2 N ln 2)
# ----------------------------------------------------------------------
def mi_miller_madow_bits(labels, proxy, n_bins_y=64):
    mi_plug, Bx, By, Bxy, N = mi_plugin_bits(labels, proxy, n_bins_y)
    bias_nats = (Bxy - Bx - By + 1) / (2.0 * N)
    bias_bits = bias_nats / math.log(2.0)
    return mi_plug - bias_bits

# ----------------------------------------------------------------------
# 3. KSG estimator (Kraskov-Stoegbauer-Grassberger, algorithm 1)
#    Works for discrete X + continuous Y by jittering X.
#    I_KSG(X;Y) = psi(k) + psi(N) - <psi(n_x+1) + psi(n_y+1)>
# ----------------------------------------------------------------------
def mi_ksg_bits(labels, proxy, k=4, jitter=1e-8, rng_seed=0):
    rng = np.random.default_rng(rng_seed)
    N = len(labels)
    x = labels.astype(np.float64).reshape(-1, 1)
    y = proxy.astype(np.float64).reshape(-1, 1)
    # standardise y, jitter x so it is "continuous enough" for the KDTree
    y = (y - y.mean()) / (y.std() + 1e-12)
    x = x + jitter * rng.standard_normal(x.shape)

    z = np.hstack([x, y])
    # epsilon = distance to k-th neighbour in joint space, Chebyshev metric
    nbrs = NearestNeighbors(n_neighbors=k + 1, metric='chebyshev').fit(z)
    eps = nbrs.kneighbors(z)[0][:, k]      # k-th NN distance, excluding self
    eps = np.nextafter(eps, 0)             # strict-less-than convention

    # n_x : # points with |x_i - x_j| < eps  (excluding i itself)
    # n_y : same for y
    tree_x = KDTree(x, metric='chebyshev')
    tree_y = KDTree(y, metric='chebyshev')
    n_x = np.array([len(tree_x.query_radius(x[i:i+1], eps[i])[0]) - 1
                    for i in range(N)])
    n_y = np.array([len(tree_y.query_radius(y[i:i+1], eps[i])[0]) - 1
                    for i in range(N)])
    n_x = np.maximum(n_x, 1)
    n_y = np.maximum(n_y, 1)

    mi_nats = (digamma(k) + digamma(N)
               - np.mean(digamma(n_x + 1) + digamma(n_y + 1)))
    mi_nats = max(mi_nats, 0.0)            # clamp to physical range
    return mi_nats / math.log(2.0)

# ----------------------------------------------------------------------
# 4. Bootstrap 95% CI
# ----------------------------------------------------------------------
def bootstrap_ci(estimator, labels, proxy, n_boot=200, seed=0,
                 subsample_frac=0.8, **kwargs):
    """
    Subsampling CI (not with-replacement bootstrap).
    With-replacement resampling creates duplicate (x,y) pairs which
    upward-bias every MI estimator. Subsampling without replacement
    avoids this bias.
    """
    rng = np.random.default_rng(seed)
    N = len(labels)
    M = int(subsample_frac * N)
    vals = np.empty(n_boot)
    for b in range(n_boot):
        idx = rng.choice(N, size=M, replace=False)
        vals[b] = estimator(labels[idx], proxy[idx], **kwargs)
    return float(np.percentile(vals, 2.5)), float(np.percentile(vals, 97.5))

# ----------------------------------------------------------------------
# 5. Driver
# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proxy',  required=True, help='.npy float64 (T,)')
    ap.add_argument('--labels', required=True, help='.npy int     (T,)')
    ap.add_argument('--design', required=True, choices=['baseline', 'qgsp'])
    ap.add_argument('--N',      required=True, type=int, choices=[64, 128, 256])
    ap.add_argument('--bins',   type=int, default=64)
    ap.add_argument('--k',      type=int, default=4)
    ap.add_argument('--boot',   type=int, default=200)
    ap.add_argument('--csv',    default='security_summary_fixed.csv')
    args = ap.parse_args()

    proxy  = np.load(args.proxy).astype(np.float64)
    labels = np.load(args.labels).astype(np.int64)
    assert len(proxy) == len(labels), "proxy and labels length mismatch"

    print(f"[*] design={args.design}  N={args.N}  T={len(proxy)}")

    mi_p, *_ = mi_plugin_bits(labels, proxy, args.bins)
    mi_mm    = mi_miller_madow_bits(labels, proxy, args.bins)
    mi_ksg   = mi_ksg_bits(labels, proxy, k=args.k)

    lo_p,  hi_p  = bootstrap_ci(lambda l, p, **kw: mi_plugin_bits(l, p, **kw)[0],
                                labels, proxy, args.boot, n_bins_y=args.bins)
    lo_mm, hi_mm = bootstrap_ci(mi_miller_madow_bits,
                                labels, proxy, args.boot, n_bins_y=args.bins)
    lo_ks, hi_ks = bootstrap_ci(mi_ksg_bits,
                                labels, proxy, args.boot, k=args.k)

    print(f"    I_plug  = {mi_p :.5f} bits   [95% CI {lo_p :.5f}, {hi_p :.5f}]")
    print(f"    I_MM    = {mi_mm:.5f} bits   [95% CI {lo_mm:.5f}, {hi_mm:.5f}]")
    print(f"    I_KSG   = {mi_ksg:.5f} bits   [95% CI {lo_ks:.5f}, {hi_ks:.5f}]")

    new_file = not os.path.exists(args.csv)
    with open(args.csv, 'a', newline='') as f:
        w = csv.writer(f)
        if new_file:
            w.writerow(['design', 'N', 'T',
                        'I_plug', 'I_plug_lo', 'I_plug_hi',
                        'I_MM',   'I_MM_lo',   'I_MM_hi',
                        'I_KSG',  'I_KSG_lo',  'I_KSG_hi'])
        w.writerow([args.design, args.N, len(proxy),
                    mi_p,  lo_p,  hi_p,
                    mi_mm, lo_mm, hi_mm,
                    mi_ksg, lo_ks, hi_ks])
    print(f"[+] appended row to {args.csv}")

if __name__ == '__main__':
    main()
