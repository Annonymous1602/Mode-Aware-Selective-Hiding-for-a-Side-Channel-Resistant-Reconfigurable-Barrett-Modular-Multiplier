#!/usr/bin/env bash
set -euo pipefail
TRACES=${TRACES:-10000}
SEED=${SEED:-12648430}
for DESIGN in baseline qgsp; do
  for N in 64 128 256; do
    echo "==== Running DESIGN=${DESIGN} N=${N} TRACES=${TRACES} ===="
    make DESIGN=${DESIGN} N=${N} TRACES=${TRACES} SEED=${SEED} sca
  done
done
make security-summary
make plots

echo "Security summary: reports/security_summary.md"
echo "Plots written to plots/"
