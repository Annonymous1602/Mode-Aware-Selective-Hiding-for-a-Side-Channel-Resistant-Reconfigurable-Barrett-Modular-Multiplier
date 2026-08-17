#!/usr/bin/env python3
"""Welch TVLA t-test on fixed-vs-random activity CSVs."""
import argparse, csv, math, statistics
parser=argparse.ArgumentParser()
parser.add_argument('fixed_csv')
parser.add_argument('random_csv')
args=parser.parse_args()

def load(path):
    vals=[]
    with open(path) as f:
        for r in csv.DictReader(f):
            vals.append(float(r['activity']))
    return vals
F=load(args.fixed_csv); R=load(args.random_csv)
if len(F)<2 or len(R)<2: raise SystemExit('need at least two samples per group')
meanF=statistics.mean(F); meanR=statistics.mean(R)
varF=statistics.variance(F); varR=statistics.variance(R)
t=(meanF-meanR)/math.sqrt(varF/len(F)+varR/len(R)) if (varF or varR) else 0.0
print(f'n_fixed={len(F)} n_random={len(R)}')
print(f'mean_fixed={meanF:.6f} mean_random={meanR:.6f}')
print(f'welch_t={t:.6f} abs_t={abs(t):.6f}')
print('TVLA_PASS' if abs(t)<4.5 else 'TVLA_FAIL')
