"""Genera keccak_rounds.cuh: round Keccak-f[1600] completamente srotolati su uint2 (lo, hi).

Il messaggio da hashare e' fisso a 84 byte  challenge(32) | sender(20) | nonce(32),
quindi sta in un solo blocco (rate 136). Varia solo la lane 9 (= nonce[20..28]).
  - FIRST_ROUND: theta del round 1 precalcolata su host, sul device si calcolano
    solo le colonne 0/3 e la lane 9 che dipendono dal nonce.
  - ROUND(rc): round generico.
  - LAST_ROUND_A0: l'ultimo round calcola solo la lane 0 (primi 8 byte del digest),
    sufficienti per il confronto con la parte alta del target.
"""

R = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
     41, 45, 15, 21, 8, 18, 2, 61, 56, 14]


def pi(i):
    x, y = i % 5, i // 5
    return y + 5 * ((2 * x + 3 * y) % 5)


import os

# lane (indice sorgente) la cui rotazione rho va sulla pipe FMA (IMAD.SHL + IMAD.HI) invece che sulla ALU (SHF):
# le due pipe lavorano in parallelo, quindi si bilancia il carico. FMA_D = quante rotazioni di theta (D) spostare.
FMA_LANES = {int(x) for x in os.environ.get("FMA_LANES", "").split(",") if x}
FMA_D = int(os.environ.get("FMA_D", "0"))


def rot(expr, n, lane=None):
    if n == 0:
        return expr
    return f"{'ROTF' if lane in FMA_LANES else 'ROTL'}({expr}, {n})"


def rho_pi_chi_iota(src, rc):
    """src[i] = espressione della lane i gia' theta-applicata."""
    out = [f"b{pi(i):02d} = " + (f"c_B[{pi(i)}]" if src[i] is None else rot(src[i], R[i], i)) + ";" for i in range(25)]
    for y in range(5):
        for x in range(5):
            j = x + 5 * y
            out.append(f"a{j:02d} = CHI(b{j:02d}, b{(x + 1) % 5 + 5 * y:02d}, b{(x + 2) % 5 + 5 * y:02d});")
    out.append(f"a00 = XOR(a00, {rc});")
    return out


def theta():
    # D[x] = C[x-1] ^ rot(C[x+1], 1) non viene materializzato: ogni lane fa a ^ C[x-1] ^ rot(C[x+1])
    # con un solo LOP3 a 3 ingressi (XOR3), risparmiando 10 LOP3 per round
    out = [f"c{x} = XOR5(a{x:02d}, a{x + 5:02d}, a{x + 10:02d}, a{x + 15:02d}, a{x + 20:02d});" for x in range(5)]
    out += [f"d{x} = {'ROTF' if x < FMA_D else 'ROTL'}(c{x}, 1);" for x in range(5)]   # d = C ruotate di 1
    return out


def macro(name, lines):
    CONT = " " + chr(92) + chr(10)
    return "#define " + name + CONT + CONT.join("    " + l for l in lines) + chr(10) + chr(10)


# lane del blocco nulle per costruzione (oltre la fine del messaggio, eccetto il pad 0x80 in lane 16)
ZERO = set(range(11, 16)) | set(range(17, 25))

first = [
    "c4 = XOR(c_C4, L9);",          # colonna 4 = S4 ^ L9 (S14,S19,S24 = 0)
    "d0 = XOR(c4, c_R1C1);",         # D0 = C4 ^ rot(C1,1)
    "d3 = XOR(c_C2, ROTL(c4, 1));",  # D3 = C2 ^ rot(C4,1)
]
src = []
for i in range(25):
    x = i % 5
    if i == 9:
        src.append("XOR(L9, c_D4)")
    elif x in (0, 3):
        d = f"d{x}"
        src.append(d if i in ZERO else f"XOR(c_S[{i}], {d})")
    else:
        src.append(None)              # costante: theta+rho+pi precalcolati su host in c_B[pi(i)]
first += rho_pi_chi_iota(src, "c_RC[0]")

gen = "// File generato da gen_rounds.py - non modificare a mano\n#pragma once\n\n"
gen += macro("FIRST_ROUND", first)
gen += macro("ROUND(rc)", theta() + rho_pi_chi_iota(
    [f"XOR3(a{i:02d}, c{(i % 5 + 4) % 5}, d{(i % 5 + 1) % 5})" for i in range(25)], "rc"))
last = [f"c{x} = XOR5(a{x:02d}, a{x + 5:02d}, a{x + 10:02d}, a{x + 15:02d}, a{x + 20:02d});" for x in range(5)]
last += [
    "d1 = ROTL(c1, 1);",
    "d2 = ROTL(c2, 1);",
    "d3 = ROTL(c3, 1);",
    f"a00 = XOR(CHI(XOR3(a00, c4, d1), ROTL(XOR3(a06, c0, d2), {R[6]}), ROTL(XOR3(a12, c1, d3), {R[12]})), c_RC[23]);",
]
gen += macro("LAST_ROUND_A0", last)
RCV = [0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
       0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
       0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]


def interleave(v):
    """lane a 64 bit -> (bit pari, bit dispari), come nel kernel"""
    e = sum(((v >> (2 * i)) & 1) << i for i in range(32))
    o = sum(((v >> (2 * i + 1)) & 1) << i for i in range(32))
    return e, o


# round 2..23 srotolati con costanti di round immediate (forma interleaved)
gen += macro("ROUNDS_1_22", ["ROUND(make_uint2({:#x}u, {:#x}u))".format(*interleave(RCV[r])) for r in range(1, 23)])

open("keccak_rounds.cuh", "w").write(gen)
print("keccak_rounds.cuh scritto")


# ---------------------------------------------------------------- round per CPU AVX2 (4 hash in parallelo)
def cpu_round():
    out = [f"c{x} = XV(XV(XV(a{x:02d}, a{x + 5:02d}), XV(a{x + 10:02d}, a{x + 15:02d})), a{x + 20:02d});" for x in range(5)]
    out += [f"d{x} = XV(c{(x + 4) % 5}, rol<1>(c{(x + 1) % 5}));" for x in range(5)]
    out += [f"b{pi(i):02d} = " + (f"XV(a00, d0)" if i == 0 else f"rol<{R[i]}>(XV(a{i:02d}, d{i % 5}))") + ";" for i in range(25)]
    for y in range(5):
        for x in range(5):
            j = x + 5 * y
            out.append(f"a{j:02d} = XV(b{j:02d}, _mm256_andnot_si256(b{(x + 1) % 5 + 5 * y:02d}, b{(x + 2) % 5 + 5 * y:02d}));")
    out.append("a00 = XV(a00, _mm256_set1_epi64x((long long)rc));")
    return out


cpu = "// File generato da gen_rounds.py - non modificare a mano\n#pragma once\n\n"
cpu += macro("CPU_ROUND(rc)", cpu_round())
open("cpu_rounds.h", "w").write(cpu)
print("cpu_rounds.h scritto")
