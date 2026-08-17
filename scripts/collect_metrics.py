#!/usr/bin/env python3
"""Collect security metrics for baseline and QGSP into one CSV/Markdown table."""
import argparse, csv, json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--traces-dir', default='traces')
p.add_argument('--out-csv', default='reports/security_summary.csv')
p.add_argument('--out-md', default='reports/security_summary.md')
p.add_argument('--designs', nargs='+', default=['baseline','qgsp'])
p.add_argument('--modes', nargs='+', default=['64','128','256'])
args = p.parse_args()

def read_json(path):
    try:
        with open(path) as f: return json.load(f)
    except FileNotFoundError:
        return {}

rows=[]
for d in args.designs:
    for n in args.modes:
        base=Path(args.traces_dir)
        tv=read_json(base/f'{d}_N{n}_tvla.json')
        qif=read_json(base/f'{d}_N{n}_qif.json')
        cpa=read_json(base/f'{d}_N{n}_cpa.json')
        rows.append({
            'design': d,
            'mode_bits': n,
            'n_fixed': tv.get('n_fixed',''),
            'n_random': tv.get('n_random', qif.get('n','')),
            'first_order_abs_t': tv.get('first_order_abs_t',''),
            'first_order_pass': tv.get('first_order_pass',''),
            'second_order_abs_t': tv.get('second_order_abs_t',''),
            'second_order_pass': tv.get('second_order_pass',''),
            'qif_mi_bits': qif.get('qif_mi_bits',''),
            'max_abs_corr': cpa.get('max_abs_corr',''),
            'best_corr_model': cpa.get('best_model',''),
        })

Path(args.out_csv).parent.mkdir(parents=True, exist_ok=True)
fields=list(rows[0].keys()) if rows else []
with open(args.out_csv,'w',newline='') as f:
    w=csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(rows)

with open(args.out_md,'w') as f:
    f.write('| Design | Mode | N fixed | N random | 1st-order |t| | 1st TVLA | 2nd-order |t| | 2nd TVLA | QIF MI bits | Max |corr| | Best CPA model |\n')
    f.write('|---|---:|---:|---:|---:|---|---:|---|---:|---:|---|\n')
    for r in rows:
        def fmt(x, nd=4):
            if x == '' or x is None: return ''
            if isinstance(x, bool): return 'Pass' if x else 'Fail'
            try: return f'{float(x):.{nd}f}'
            except Exception: return str(x)
        f.write(f"| {r['design']} | {r['mode_bits']} | {r['n_fixed']} | {r['n_random']} | {fmt(r['first_order_abs_t'])} | {fmt(r['first_order_pass'])} | {fmt(r['second_order_abs_t'])} | {fmt(r['second_order_pass'])} | {fmt(r['qif_mi_bits'],6)} | {fmt(r['max_abs_corr'],6)} | {r['best_corr_model']} |\n")
print(f'wrote {args.out_csv}')
print(f'wrote {args.out_md}')
