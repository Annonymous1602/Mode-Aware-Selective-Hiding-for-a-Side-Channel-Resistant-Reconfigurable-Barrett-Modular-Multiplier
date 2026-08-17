#!/usr/bin/env bash
set -euo pipefail
DESIGN=${DESIGN:-qgsp}
TRACES=${TRACES:-10000}
SEED=${SEED:-12648430}
for N in 64 128 256; do
  make DESIGN=${DESIGN} N=${N} TRACES=${TRACES} SEED=${SEED} sca
done
make security-summary
make plots
