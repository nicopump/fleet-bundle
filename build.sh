#!/usr/bin/env bash
# Compila keccak_miner per la GPU presente (Linux). Uso: ./build.sh [arch, es. sm_120]
set -euo pipefail
cd "$(dirname "$0")"
ARCH="${1:-sm_$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)}"
echo "build per $ARCH"
python3 gen_rounds.py
nvcc -O3 -arch="$ARCH" -std=c++17 -lineinfo -Xptxas -v -Xcompiler "-O3 -mavx2" \
     -o keccak_miner keccak_miner.cu cpu_miner.cpp
nvcc -O3 -arch="$ARCH" -o tools/pipebench tools/pipebench.cu
