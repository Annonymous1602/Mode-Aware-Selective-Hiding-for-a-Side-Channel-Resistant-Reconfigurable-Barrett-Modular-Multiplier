#!/usr/bin/env bash
set -euo pipefail
for DESIGN in baseline qgsp; do
  for N in 64 128 256; do
    echo "==== Vivado synth DESIGN=${DESIGN} N=${N} ===="
    make DESIGN=${DESIGN} N=${N} vivado-synth
  done
done
make parse-vivado
make hardware-plots
