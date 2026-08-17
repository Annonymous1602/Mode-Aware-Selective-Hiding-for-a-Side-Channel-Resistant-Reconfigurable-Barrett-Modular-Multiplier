#!/usr/bin/env python3
"""Plot security/hardware metrics from summary CSV files."""
import argparse, csv
from pathlib import Path
import matplotlib.pyplot as plt

p = argparse.ArgumentParser()
p.add_argument('--security-csv', default='reports/security_summary.csv')
p.add_argument('--hardware-csv', default='reports/hardware_summary.csv')
p.add_argument('--outdir', default='plots')
args = p.parse_args()

out = Path(args.outdir); out.mkdir(parents=True, exist_ok=True)

def read_csv(path):
    try:
        with open(path, newline='') as f: return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

def fnum(x):
    try: return float(x)
    except Exception: return 0.0

def grouped_bar(rows, metric, title, ylabel, fname, threshold=None):
    if not rows: return
    labels = [f"{r['design']} N{r['mode_bits']}" for r in rows]
    vals = [fnum(r.get(metric,'')) for r in rows]
    plt.figure(figsize=(max(9, len(labels)*0.75), 4.8))
    plt.bar(labels, vals)
    if threshold is not None:
        plt.axhline(threshold, linestyle='--', linewidth=1.5)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(rotation=35, ha='right')
    plt.tight_layout()
    plt.savefig(out/fname, dpi=200)
    plt.close()

sec = read_csv(args.security_csv)
grouped_bar(sec, 'first_order_abs_t', 'First-order TVLA comparison', 'Absolute Welch t-value', 'tvla_first_order.png', threshold=4.5)
grouped_bar(sec, 'second_order_abs_t', 'Second-order TVLA comparison', 'Absolute Welch t-value', 'tvla_second_order.png', threshold=4.5)
grouped_bar(sec, 'qif_mi_bits', 'QIF leakage proxy comparison', 'Mutual information proxy (bits)', 'qif_proxy.png')
grouped_bar(sec, 'max_abs_corr', 'CPA/correlation leakage comparison', 'Maximum absolute Pearson correlation', 'cpa_correlation.png')

hw = read_csv(args.hardware_csv)
for metric, title, ylabel, fname in [
    ('lut_overhead_pct','LUT overhead vs baseline','Overhead (%)','lut_overhead.png'),
    ('ff_overhead_pct','FF overhead vs baseline','Overhead (%)','ff_overhead.png'),
    ('power_overhead_pct','Power overhead vs baseline','Overhead (%)','power_overhead.png'),
    ('delay_overhead_pct','Delay overhead vs baseline','Overhead (%)','delay_overhead.png'),
]:
    if hw and metric in hw[0]:
        grouped_bar([r for r in hw if r.get('design') == 'qgsp'], metric, title, ylabel, fname, threshold=20.0)
print(f'wrote plots to {out}')
