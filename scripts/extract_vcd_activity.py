#!/usr/bin/env python3
"""Extract per-operation VCD toggle activity.

v5 change:
  The older extractor counted a whole vector assignment as one toggle, e.g.
  b101010 <code> counted as 1 even if hundreds/thousands of bits changed.
  That made large balancing banks almost invisible. This version counts
  bit-level Hamming-distance changes for vector values by default.

Trace segmentation:
  A new operation starts on a rising edge of the testbench signal named
  `trigger`. Activity is counted between successive trigger rising edges.
"""
import argparse
import csv
import re

parser = argparse.ArgumentParser()
parser.add_argument('vcd')
parser.add_argument('out_csv')
parser.add_argument('--include-clocks', action='store_true')
parser.add_argument('--vector-mode', choices=['bit_hd', 'event'], default='bit_hd',
                    help='bit_hd counts per-bit Hamming distance for vectors; event counts one change per vector event')
args = parser.parse_args()

code_to_name = {}
code_to_width = {}
name_to_code = {}
trigger_code = None
clk_like = set()
values = {}
rows = []
cur_toggles = None
trace_idx = -1
in_header = True

var_re = re.compile(r'^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(.+?)\s+\$end')

def canonical_scalar(v):
    v = v.lower()
    return '1' if v in ('1', 'b1') else '0' if v in ('0', 'b0') else 'x'

def canonical_bits(v, width):
    """Return a fixed-width string of 0/1/x for a VCD scalar/vector value."""
    v = v.strip().lower()
    if v.startswith('b') or v.startswith('r'):
        bits = v[1:]
    else:
        bits = v
    bits = ''.join(ch if ch in '01' else 'x' for ch in bits)
    if width <= 0:
        width = len(bits)
    if len(bits) < width:
        # VCD vectors can omit leading zeros; pad on the left.
        bits = ('0' * (width - len(bits))) + bits
    elif len(bits) > width:
        bits = bits[-width:]
    return bits

def bit_hd(old_v, new_v, width):
    old_bits = canonical_bits(old_v, width)
    new_bits = canonical_bits(new_v, width)
    # Count a transition if the represented bit changes. Unknowns are counted
    # only when the symbol changes; this keeps X/Z activity visible but bounded.
    return sum(1 for a, b in zip(old_bits, new_bits) if a != b)

def is_trigger_rise(old, new):
    return canonical_scalar(new) == '1' and canonical_scalar(old or '0') != '1'

def record_change(code, value):
    global trigger_code, cur_toggles, trace_idx
    old = values.get(code)
    width = code_to_width.get(code, 1)
    values[code] = value

    if code == trigger_code and is_trigger_rise(old, value):
        if cur_toggles is not None:
            rows.append({'trace': trace_idx, 'activity': cur_toggles})
        trace_idx += 1
        cur_toggles = 0
        return

    if cur_toggles is None or old is None or old == value:
        return
    if (not args.include_clocks) and code in clk_like:
        return

    if args.vector_mode == 'event' or width <= 1:
        cur_toggles += 1
    else:
        cur_toggles += bit_hd(old, value, width)

with open(args.vcd, 'r', errors='ignore') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        if in_header:
            m = var_re.match(line)
            if m:
                width = int(m.group(1))
                code = m.group(2)
                name = m.group(3).split()[0]
                code_to_name[code] = name
                code_to_width[code] = width
                name_to_code.setdefault(name, code)
                lname = name.lower()
                if lname == 'trigger':
                    trigger_code = code
                if lname in ('clk', 'clock', 'start', 'trigger') or 'clk' in lname:
                    clk_like.add(code)
            if line == '$enddefinitions $end':
                in_header = False
                if trigger_code is None:
                    raise SystemExit('ERROR: trigger signal not found in VCD')
            continue

        if line[0] == '#':
            continue
        if line[0] in '01xzXZ':
            record_change(line[1:], line[0].lower())
        elif line[0] in 'brBR':
            parts = line.split()
            if len(parts) == 2:
                record_change(parts[1], parts[0].lower())

if cur_toggles is not None:
    rows.append({'trace': trace_idx, 'activity': cur_toggles})

with open(args.out_csv, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['trace', 'activity'])
    w.writeheader()
    w.writerows(rows)
print(f'wrote {len(rows)} trace activity rows to {args.out_csv} using vector_mode={args.vector_mode}')
