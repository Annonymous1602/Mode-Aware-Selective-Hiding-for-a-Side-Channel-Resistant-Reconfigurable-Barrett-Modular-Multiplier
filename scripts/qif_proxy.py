#!/usr/bin/env python3
"""QIF-style proxy: mutual information between binned secret label and activity.
This is not a formal proof; it is a repeatable leakage metric for RTL/VCD traces.
Secret label defaults to HW((A*B) mod 2^N) binned modulo --secret-bins.
"""
import argparse, csv, math, collections, json
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('operands_txt')
parser.add_argument('activity_csv')
parser.add_argument('--N', type=int, required=True, choices=[64,128,256])
parser.add_argument('--activity-bins', type=int, default=16)
parser.add_argument('--secret-bins', type=int, default=16)
parser.add_argument('--out-json')
parser.add_argument('--out-csv')
args=parser.parse_args()

def hw(x): return int(x).bit_count()
acts=[]
with open(args.activity_csv, newline='') as f:
    for r in csv.DictReader(f): acts.append(float(r['activity']))
ops=[]
mask=(1<<args.N)-1
with open(args.operands_txt) as f:
    for line in f:
        p=line.split()
        if len(p)>=2:
            a=int(p[0],16)&mask; b=int(p[1],16)&mask
            ops.append((a,b))
n=min(len(acts), len(ops))
acts=acts[:n]; ops=ops[:n]
if n<2: raise SystemExit('not enough samples')
mn=min(acts); mx=max(acts)
def abin(x):
    if mx==mn: return 0
    return min(args.activity_bins-1, int((x-mn)/(mx-mn+1e-12)*args.activity_bins))
S=[]; L=[]
for (a,b),act in zip(ops,acts):
    S.append(hw((a*b)&mask) % args.secret_bins)
    L.append(abin(act))
cs=collections.Counter(S); cl=collections.Counter(L); csl=collections.Counter(zip(S,L))
mi=0.0
for (s,l),c in csl.items():
    prob=c/n; ps=cs[s]/n; pl=cl[l]/n
    mi += prob*math.log2(prob/(ps*pl))
res={'n':n,'qif_mi_bits':mi,'qif_display_4dp':round(mi,4),'activity_bins':args.activity_bins,'secret_bins':args.secret_bins}
print(f'n={n}')
print(f'qif_mi_bits={mi:.8f}')
print(f'qif_display_4dp={mi:.4f}')
if args.out_json:
    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json,'w') as f: json.dump(res,f,indent=2)
if args.out_csv:
    Path(args.out_csv).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_csv,'w',newline='') as f:
        w=csv.DictWriter(f, fieldnames=list(res.keys()))
        w.writeheader(); w.writerow(res)
