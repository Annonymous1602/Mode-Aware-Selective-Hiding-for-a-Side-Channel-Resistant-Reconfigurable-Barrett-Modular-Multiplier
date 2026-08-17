#!/usr/bin/env bash
set -euo pipefail
TRACES=${TRACES:-10000}
for BITS in 4096 8192 16384 32768; do
  echo "==== QGSP 64-bit strength sweep: SEC64_TOGGLE_BITS=${BITS}, TRACES=${TRACES} ===="
  make DESIGN=qgsp N=64 TRACES=${TRACES} SEC64_TOGGLE_BITS=${BITS} sca
  cp traces/qgsp_N64_tvla.txt traces/qgsp_N64_tvla_secbits_${BITS}.txt
  cp traces/qgsp_N64_cpa.txt traces/qgsp_N64_cpa_secbits_${BITS}.txt
  cp traces/qgsp_N64_qif.txt traces/qgsp_N64_qif_secbits_${BITS}.txt
  echo
  grep -E "FIRST_ORDER|SECOND_ORDER|abs_t|max_abs_corr|qif_display" traces/qgsp_N64_tvla.txt traces/qgsp_N64_cpa.txt traces/qgsp_N64_qif.txt || true
  echo
  make clean
  mkdir -p traces reports plots
 done
