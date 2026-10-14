#!/usr/bin/env bash
# Campagna "massimo" sulla 5090: varianti del kernel misurate a cicli (hash/clk/SM), co-mining CPU, info su clock/potenza.
# Uso: ./max_5090.sh            (circa 15 minuti)
set -uo pipefail
cd "$(dirname "$0")"
ARCH=sm_$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)
mkdir -p bin
CH=0x$(printf 'ab%.0s' $(seq 1 32))
ADDR=0x1111111111111111111111111111111111111111

build() {   # build NOME "VAR=val ..." "flag nvcc"
    local name=$1 envs=$2 flags=$3
    env $envs python3 gen_rounds.py > /dev/null
    nvcc -O3 -arch=$ARCH -std=c++17 -Xptxas -v -Xcompiler "-O3 -mavx2" $flags \
         -o bin/$name keccak_miner.cu cpu_miner.cpp 2> bin/$name.ptxas || { echo "$name: BUILD FALLITA"; return 1; }
    local regs spill
    regs=$(grep -A2 "mine_opt_tILb0" bin/$name.ptxas | grep -o "Used [0-9]* registers" | grep -o "[0-9]*")
    spill=$(grep -A2 "mine_opt_tILb0" bin/$name.ptxas | grep -o "[0-9]* bytes spill stores" | grep -o "^[0-9]*")
    echo "$name: registri $regs, spill $spill"
}
check() {   # correttezza: selftest + debug
    local st dbg
    st=$(./bin/$1 selftest 2>/dev/null | grep SELFTEST)
    dbg=$(./bin/$1 debug 2>/dev/null | awk '{split($2,g,"=");split($3,c,"="); if (g[2]!=c[2]) m++} END {print m+0}')
    echo "  $st | debug mismatch $dbg"
}
cyc3() {    # migliore di 3 misure a cicli
    local best=0 v
    for i in 1 2 3; do
        v=$(./bin/$1 cyc 15 ${2:-128} ${3:-16} 2>/dev/null)
        echo "    $v"
    done
}

echo "== sistema"
nvidia-smi --query-gpu=name,compute_cap,clocks.max.sm,clocks.max.mem,power.limit,power.max_limit,driver_version --format=csv
echo "CPU disponibili al container: $(nproc)   AVX2: $(grep -c avx2 /proc/cpuinfo | head -1)   AVX-512: $(grep -c avx512f /proc/cpuinfo | head -1)"
echo "== permessi su clock/potenza (solo lettura dello stato)"
nvidia-smi -q -d PERFORMANCE | grep -iE "Clocks Event|Idle|Power Cap|Thermal|Applications" | head -12

echo; echo "== A. base (kernel attuale)"
build base "" "" && check base && cyc3 base

echo; echo "== B. configurazioni di lancio (tpb bpsm)"
for cfg in "64 32" "128 8" "128 12" "128 16" "192 8" "256 4" "256 6" "256 8"; do
    echo -n "  $cfg: "; ./bin/base cyc 15 $cfg 2>/dev/null
done

echo; echo "== C. srotolamento dei round"
for u in 1 2; do build unroll$u "" "-DUNROLL_R=$u" && check unroll$u && cyc3 unroll$u; done

echo; echo "== D. chiusura offload rotazioni su IMAD (atteso negativo dalla 4060)"
build p1_k8  "FMA_LANES=2,3,4,5"          "-DROT_PRIM=1" && check p1_k8  && cyc3 p1_k8
build p2_k8  "FMA_LANES=2,3,4,5"          "-DROT_PRIM=2" && check p2_k8  && cyc3 p2_k8
build p1_k20 "FMA_LANES=2,3,4,5,6,7,8,9,10,11" "-DROT_PRIM=1" && check p1_k20 && cyc3 p1_k20
build p2_k20 "FMA_LANES=2,3,4,5,6,7,8,9,10,11" "-DROT_PRIM=2" && check p2_k20 && cyc3 p2_k20
build p0_k20 "FMA_LANES=2,3,4,5,6,7,8,9,10,11" "-DROT_PRIM=0" && check p0_k20 && cyc3 p0_k20
python3 gen_rounds.py > /dev/null   # ripristina i round di default

echo; echo "== E. co-mining CPU (GPU + thread CPU AVX2, 45 s per riga)"
NP=$(nproc)
for t in 0 $((NP / 2)) $((NP - 1)); do
    echo -n "  CPU $t thread: "
    ./bin/base mine "$CH" $ADDR 0x0 --cpu-threads $t --secs 45 2>/dev/null | tail -1 \
        | awk '{printf "totale %s MH/s (GPU %s + CPU %s)\n", $2, $5, $6}'
done
echo; echo "== fine campagna"
