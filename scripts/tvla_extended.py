#!/usr/bin/env python3
"""First-order and second-order Welch TVLA from per-operation activity CSVs.

Input CSVs must contain at least: trace,activity.
Second-order TVLA here uses centered-squared aggregate activity:
    L2 = (L - mean(F union R))^2
This is a simulation-level aggregate leakage test. For sample-point traces, use the
same formula per time sample/window.
"""
import argparse, csv, json, math, statistics
from pathlib import Path

THRESHOLD = 4.5

p = argparse.ArgumentParser()
p.add_argument('fixed_csv')
p.add_argument('random_csv')
p.add_argument('--out-json')
p.add_argument('--out-csv')
args = p.parse_args()

def load(path):
    vals = []
    with open(path, newline='') as f:
        for r in csv.DictReader(f):
            vals.append(float(r['activity']))
    return vals

def welch_t(a, b):
    if len(a) < 2 or len(b) < 2:
        raise SystemExit('need at least two samples per group')
    ma, mb = statistics.mean(a), statistics.mean(b)
    va, vb = statistics.variance(a), statistics.variance(b)
    den = math.sqrt(va/len(a) + vb/len(b))
    return 0.0 if den == 0 else (ma - mb) / den, ma, mb, va, vb

F = load(args.fixed_csv)
R = load(args.random_csv)
all_vals = F + R
center = statistics.mean(all_vals)
F2 = [(x - center) ** 2 for x in F]
R2 = [(x - center) ** 2 for x in R]

t1, meanF, meanR, varF, varR = welch_t(F, R)
t2, meanF2, meanR2, varF2, varR2 = welch_t(F2, R2)

res = {
    'n_fixed': len(F),
    'n_random': len(R),
    'mean_fixed': meanF,
    'mean_random': meanR,
    'first_order_t': t1,
    'first_order_abs_t': abs(t1),
    'first_order_pass': abs(t1) < THRESHOLD,
    'second_order_center': center,
    'second_order_mean_fixed': meanF2,
    'second_order_mean_random': meanR2,
    'second_order_t': t2,
    'second_order_abs_t': abs(t2),
    'second_order_pass': abs(t2) < THRESHOLD,
    'threshold': THRESHOLD,
}

print(f"n_fixed={res['n_fixed']} n_random={res['n_random']}")
print(f"first_mean_fixed={meanF:.6f} first_mean_random={meanR:.6f}")
print(f"first_order_welch_t={t1:.6f} first_order_abs_t={abs(t1):.6f}")
print('FIRST_ORDER_TVLA_PASS' if res['first_order_pass'] else 'FIRST_ORDER_TVLA_FAIL')
print(f"second_center={center:.6f}")
print(f"second_mean_fixed={meanF2:.6f} second_mean_random={meanR2:.6f}")
print(f"second_order_welch_t={t2:.6f} second_order_abs_t={abs(t2):.6f}")
print('SECOND_ORDER_TVLA_PASS' if res['second_order_pass'] else 'SECOND_ORDER_TVLA_FAIL')

if args.out_json:
    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json, 'w') as f:
        json.dump(res, f, indent=2)
if args.out_csv:
    Path(args.out_csv).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_csv, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(res.keys()))
        w.writeheader(); w.writerow(res)
