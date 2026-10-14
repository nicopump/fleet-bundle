#!/usr/bin/env bash
# Prova sostenuta: configurazione migliore (kernel base, 256x8, 15 thread CPU), campioni nvidia-smi ogni 30 s.
cd /root/max
SECS=${1:-600}
CH=0x$(printf 'ab%.0s' $(seq 1 32))
( for i in $(seq 1 $((SECS / 30))); do sleep 30
    echo "$((i * 30))s $(nvidia-smi --query-gpu=clocks.sm,power.draw,temperature.gpu,fan.speed,clocks_event_reasons.active --format=csv,noheader)"
  done ) > sustained_smi.log &
./bin/base mine "$CH" 0x1111111111111111111111111111111111111111 0x0 --tpb 256 --bpsm 8 --cpu-threads 15 --secs "$SECS" \
    > sustained_status.log 2>/dev/null
wait
echo FINE >> sustained_status.log
