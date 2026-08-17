#!/usr/bin/env python3
"""Correlation/CPA-style leakage test from operand log and aggregate activity.

This is not a full key-recovery CPA because the RBMM test vectors do not include a
secret-key hypothesis. It computes Pearson correlation between measured toggle
activity and several sensitive-value leakage models. Large |r| indicates exploitable
linear leakage under that model.
"""
import argparse, csv, json, math, statistics
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('operands_txt')
p.add_argument('activity_csv')
p.add_argument('--N', type=int, required=True, choices=[64,128,256])
p.add_argument('--out-json')
p.add_argument('--out-csv')
args = p.parse_args()

def hw(x): return int(x).bit_count()
def pearson(x, y):
    n = min(len(x), len(y))
    if n < 3: return 0.0
    x = x[:n]; y = y[:n]
    mx = statistics.mean(x); my = statistics.mean(y)
    sx = math.sqrt(sum((v-mx)**2 for v in x))
    sy = math.sqrt(sum((v-my)**2 for v in y))
    if sx == 0 or sy == 0: return 0.0
    return sum((a-mx)*(b-my) for a,b in zip(x,y)) / (sx*sy)

acts = []
with open(args.activity_csv, newline='') as f:
    for r in csv.DictReader(f): acts.append(float(r['activity']))
ops = []
mask = (1 << args.N) - 1
with open(args.operands_txt) as f:
    for line in f:
        toks = line.split()
        if len(toks) >= 2:
            a = int(toks[0], 16) & mask
            b = int(toks[1], 16) & mask
            ops.append((a,b))

n = min(len(acts), len(ops))
acts = acts[:n]; ops = ops[:n]
if n < 3: raise SystemExit('not enough samples')

models = {
    'HW_A': [hw(a) for a,b in ops],
    'HW_B': [hw(b) for a,b in ops],
    'HW_A_xor_B': [hw(a ^ b) for a,b in ops],
    'HW_AB_lowN': [hw((a*b) & mask) for a,b in ops],
    'HW_AB_low64': [hw((a*b) & ((1<<64)-1)) for a,b in ops],
    'HD_A_B': [hw(a ^ b) for a,b in ops],
}
rows = []
for name, vals in models.items():
    r = pearson(vals, acts)
    rows.append({'model': name, 'correlation': r, 'abs_correlation': abs(r)})
rows.sort(key=lambda d: d['abs_correlation'], reverse=True)
best = rows[0]
res = {'n': n, 'best_model': best['model'], 'max_abs_corr': best['abs_correlation'], 'best_corr': best['correlation'], 'models': rows}

print(f'n={n}')
for row in rows:
    print(f"{row['model']}: corr={row['correlation']:.8f} abs_corr={row['abs_correlation']:.8f}")
print(f"max_abs_corr={res['max_abs_corr']:.8f} best_model={res['best_model']}")

if args.out_json:
    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json, 'w') as f: json.dump(res, f, indent=2)
if args.out_csv:
    Path(args.out_csv).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_csv, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['model','correlation','abs_correlation'])
        w.writeheader(); w.writerows(rows)
