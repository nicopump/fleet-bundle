#!/usr/bin/env bash
# Benchmark completo su macchina cloud: sistema, correttezza, pipe, hash per clock, carico sostenuto.
# Uso: ./cloud_bench.sh [secondi di carico sostenuto, default 180]
set -uo pipefail
cd "$(dirname "$0")"
SECS="${1:-180}"
echo "== sistema"
nvidia-smi --query-gpu=name,compute_cap,clocks.max.sm,power.limit,driver_version --format=csv
nvcc --version | tail -2
lscpu | grep -E "Model name|^CPU\(s\)"
echo "== build"
./build.sh 2>&1 | grep -E "build per|error|Used [0-9]+ registers|spill stores" | sort -u
echo "== correttezza"
./keccak_miner selftest 2>/dev/null | grep -v '^SOL'
./keccak_miner debug 2>/dev/null
echo "== pipe (istruzioni per clock per SM)"
./tools/pipebench
echo "== hash per clock per SM, per configurazione di lancio (tpb bpsm)"
for cfg in "128 16" "256 8" "64 32" "256 4" "128 8"; do
    echo -n "$cfg: "
    ./keccak_miner cyc 15 $cfg 2>/dev/null
done
echo "== carico sostenuto ${SECS} s (clock MHz, potenza, temperatura, motivi di rallentamento)"
( for i in $(seq 1 $((SECS / 15))); do sleep 15; nvidia-smi --query-gpu=clocks.sm,power.draw,temperature.gpu,clocks_event_reasons.active --format=csv,noheader; done ) &
CH=0x$(printf 'ab%.0s' $(seq 1 32))
./keccak_miner mine "$CH" 0x1111111111111111111111111111111111111111 0x0 --secs "$SECS" 2>/dev/null | tail -1 \
    | awk '{printf "STATUS: totale %s MH/s in %s s (GPU %s MH/s)\n", $2, $4, $5}'
wait
