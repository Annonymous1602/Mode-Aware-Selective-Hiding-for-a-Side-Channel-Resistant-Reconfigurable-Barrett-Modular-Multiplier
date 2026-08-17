#!/usr/bin/env python3
"""Parse Vivado utilization/timing/power reports and compute QGSP overhead.

Expected files by default:
  reports/vivado/<design>_N<mode>_util.rpt
  reports/vivado/<design>_N<mode>_timing.rpt
  reports/vivado/<design>_N<mode>_power.rpt
where design is baseline or qgsp, and mode is 64, 128, 256.
"""
import argparse, csv, re
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--report-dir', default='reports/vivado')
p.add_argument('--out-csv', default='reports/hardware_summary.csv')
p.add_argument('--designs', nargs='+', default=['baseline','qgsp'])
p.add_argument('--modes', nargs='+', default=['64','128','256'])
args = p.parse_args()
root = Path(args.report_dir)

def text(path):
    try: return Path(path).read_text(errors='ignore')
    except FileNotFoundError: return ''

def parse_util(s):
    # Works for common Vivado tables. Keeps parsing conservative.
    out = {'lut':'','ff':'','dsp':'','bram':''}
    m = re.search(r'\|\s*Slice LUTs\s*\|\s*([0-9,]+)', s, re.I)
    if m: out['lut'] = int(m.group(1).replace(',',''))
    m = re.search(r'\|\s*Slice Registers\s*\|\s*([0-9,]+)', s, re.I)
    if m: out['ff'] = int(m.group(1).replace(',',''))
    m = re.search(r'\|\s*DSPs\s*\|\s*([0-9,]+)', s, re.I)
    if m: out['dsp'] = int(m.group(1).replace(',',''))
    m = re.search(r'\|\s*Block RAM Tile\s*\|\s*([0-9,]+)', s, re.I)
    if m: out['bram'] = int(m.group(1).replace(',',''))
    return out

def parse_timing(s):
    # Prefer data path delay when available; otherwise use requirement - WNS.
    out={'wns':'','delay':''}
    m = re.search(r'WNS\(ns\)\s*[:=]?\s*(-?[0-9.]+)', s, re.I)
    if m: out['wns'] = float(m.group(1))
    m = re.search(r'Data Path Delay\s*[:=]\s*([0-9.]+)ns', s, re.I)
    if m: out['delay'] = float(m.group(1))
    return out

def parse_power(s):
    out={'power':''}
    m = re.search(r'\|\s*Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)', s, re.I)
    if not m:
        m = re.search(r'Total On-Chip Power.*?([0-9.]+)\s*W', s, re.I)
    if m: out['power'] = float(m.group(1))
    return out

def pct(new, old):
    try:
        new=float(new); old=float(old)
        if old == 0: return ''
        return (new-old)/old*100.0
    except Exception:
        return ''

rows=[]; data={}
for d in args.designs:
    for n in args.modes:
        rec={'design':d,'mode_bits':n}
        rec.update(parse_util(text(root/f'{d}_N{n}_util.rpt')))
        rec.update(parse_timing(text(root/f'{d}_N{n}_timing.rpt')))
        rec.update(parse_power(text(root/f'{d}_N{n}_power.rpt')))
        data[(d,n)] = rec

for n in args.modes:
    b=data.get(('baseline',n),{})
    for d in args.designs:
        rec=dict(data[(d,n)])
        if d != 'baseline':
            rec['lut_overhead_pct']=pct(rec.get('lut',''), b.get('lut',''))
            rec['ff_overhead_pct']=pct(rec.get('ff',''), b.get('ff',''))
            rec['dsp_overhead_pct']=pct(rec.get('dsp',''), b.get('dsp',''))
            rec['bram_overhead_pct']=pct(rec.get('bram',''), b.get('bram',''))
            rec['power_overhead_pct']=pct(rec.get('power',''), b.get('power',''))
            rec['delay_overhead_pct']=pct(rec.get('delay',''), b.get('delay',''))
        else:
            rec['lut_overhead_pct']=rec['ff_overhead_pct']=rec['dsp_overhead_pct']=rec['bram_overhead_pct']=''
            rec['power_overhead_pct']=rec['delay_overhead_pct']=''
        rows.append(rec)

Path(args.out_csv).parent.mkdir(parents=True, exist_ok=True)
fields=['design','mode_bits','lut','ff','dsp','bram','power','wns','delay','lut_overhead_pct','ff_overhead_pct','dsp_overhead_pct','bram_overhead_pct','power_overhead_pct','delay_overhead_pct']
with open(args.out_csv,'w',newline='') as f:
    w=csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(rows)
print(f'wrote {args.out_csv}')
