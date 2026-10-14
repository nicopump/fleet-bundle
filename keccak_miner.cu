// Miner CUDA per Seasonal Tokens (ERC-918):  keccak256(challenge(32) | sender(20) | nonce(32)) <= target
//
//   keccak_miner bench [secondi]                     benchmark kernel naive vs ottimizzato + tuning
//   keccak_miner selftest                            trova soluzioni con target facile e le verifica su CPU
//   keccak_miner mine <challenge> <sender> <target> [--exact-one] [--tpb N] [--bpsm N]
//
// Output di "mine" (una riga per evento, stdout con flush):
//   STATUS <MH/s totali> <hash_totali> <secondi> <MH/s GPU> <MH/s CPU>
//   FOUND <nonce 0x..64> <digest 0x..64>
#include <cuda_runtime.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>

#include "cpu_miner.h"

static void ck(cudaError_t e, const char *what, int line) {
    if (e != cudaSuccess) { fprintf(stderr, "CUDA error %s (%s) line %d\n", cudaGetErrorString(e), what, line); exit(2); }
}
#define CK(x) ck((x), #x, __LINE__)

typedef unsigned long long u64;

static const u64 RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
static const int RHO[25] = {0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
                            41, 45, 15, 21, 8, 18, 2, 61, 56, 14};

// ---------------------------------------------------------------- CPU reference (verifica)
static inline u64 rotl64(u64 v, int n) { return n ? (v << n) | (v >> (64 - n)) : v; }

static void keccakf_cpu(u64 A[25]) {
    for (int r = 0; r < 24; r++) {
        u64 C[5], D[5], B[25];
        for (int x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
        for (int x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 1);
        for (int i = 0; i < 25; i++) {
            int x = i % 5, y = i / 5;
            B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(A[i] ^ D[x], RHO[i]);
        }
        for (int i = 0; i < 25; i++) {
            int x = i % 5, y = i / 5;
            A[i] = B[i] ^ (~B[(x + 1) % 5 + 5 * y] & B[(x + 2) % 5 + 5 * y]);
        }
        A[0] ^= RC[r];
    }
}

// keccak256 di un messaggio <= 135 byte (un solo blocco)
static void keccak256_cpu(const uint8_t *msg, int len, uint8_t out[32]) {
    uint8_t blk[136] = {0};
    memcpy(blk, msg, len);
    blk[len] ^= 0x01;
    blk[135] ^= 0x80;
    u64 A[25] = {0};
    for (int i = 0; i < 17; i++) memcpy(&A[i], blk + 8 * i, 8);
    keccakf_cpu(A);
    memcpy(out, A, 32);
}

// ---------------------------------------------------------------- costanti device
__constant__ uint2 c_S[25];   // lane di input con lane 9 = 0
__constant__ uint2 c_B[25];   // lane costanti dopo theta+rho+pi nel round 1 (posizione di destinazione)
__constant__ uint2 c_C4, c_R1C1, c_C2, c_D4;
__constant__ uint2 c_RC[24];
__constant__ uint2 c_T0;      // 64 bit alti nel target (x = parte bassa, y = parte alta)
__constant__ u64 c_lanes[17]; // per il kernel naive
__constant__ u64 d_RC[24];
__constant__ int d_RHO[25];

#define XOR(a, b) make_uint2((a).x ^ (b).x, (a).y ^ (b).y)
#define XOR5(a, b, c, d, e) make_uint2((a).x ^ (b).x ^ (c).x ^ (d).x ^ (e).x, (a).y ^ (b).y ^ (c).y ^ (d).y ^ (e).y)
// XOR a 3 ingressi forzato in un singolo LOP3 (impedisce al compilatore di ri-fattorizzare D di theta)
__device__ __forceinline__ unsigned xor3u(const unsigned a, const unsigned b, const unsigned c) {
    unsigned r;
    asm("lop3.b32 %0, %1, %2, %3, 0x96;" : "=r"(r) : "r"(a), "r"(b), "r"(c));
    return r;
}
#define XOR3(a, b, c) make_uint2(xor3u((a).x, (b).x, (c).x), xor3u((a).y, (b).y, (c).y))
#define CHI(a, b, c) make_uint2((a).x ^ (~(b).x & (c).x), (a).y ^ (~(b).y & (c).y))

// Lane in forma bit-interleaved: x = bit pari, y = bit dispari della lane a 64 bit.
// Rotazione di r: r pari -> due rotazioni a 32 bit di r/2; r dispari -> scambio + rotazioni
// di (r+1)/2 e (r-1)/2. Per r = 1 (5 volte in theta + 1 in rho per round) basta una sola SHF.
__device__ __forceinline__ unsigned rot32(const unsigned v, const int k) {
    return k == 0 ? v : __funnelshift_l(v, v, k);
}
__device__ __forceinline__ uint2 ROTL(const uint2 v, const int r) {
    if (r & 1) return make_uint2(rot32(v.y, (r + 1) / 2), rot32(v.x, (r - 1) / 2));
    return make_uint2(rot32(v.x, r / 2), rot32(v.y, r / 2));
}

// Stessa rotazione ma sulla pipe FMA: rot32(x, k) = hi(x * 2^k) + lo(x * 2^k) (IMAD.SHL + IMAD.HI).
// I moltiplicatori stanno in memoria costante perche il compilatore non li riconosca come shift.
__constant__ unsigned c_pow2[32];
#ifndef ROT_PRIM
#define ROT_PRIM 0   // 0: mul.lo -> mad.hi; 1: mul.hi -> mad.lo; 2: mul.wide -> mad.lo (vedi README)
#endif
__device__ __forceinline__ unsigned rot32f(const unsigned x, const int k) {
    if (k == 0) return x;
    const unsigned p = c_pow2[k];
    unsigned r;
#if ROT_PRIM == 0
    unsigned lo;
    asm("mul.lo.u32 %0, %1, %2;" : "=r"(lo) : "r"(x), "r"(p));
    asm("mad.hi.u32 %0, %1, %2, %3;" : "=r"(r) : "r"(x), "r"(p), "r"(lo));
#elif ROT_PRIM == 1
    unsigned hi;   // parte alta prima, poi x*2^k + hi: niente coppia di registri a 64 bit
    asm("mul.hi.u32 %0, %1, %2;" : "=r"(hi) : "r"(x), "r"(p));
    asm("mad.lo.u32 %0, %1, %2, %3;" : "=r"(r) : "r"(x), "r"(p), "r"(hi));
#else
    unsigned long long w;   // prodotto a 64 bit in un colpo, poi hi*1 + lo sulla pipe FMA (1 da memoria costante)
    asm("mul.wide.u32 %0, %1, %2;" : "=l"(w) : "r"(x), "r"(p));
    asm("mad.lo.u32 %0, %1, %2, %3;" : "=r"(r) : "r"((unsigned)(w >> 32)), "r"(c_pow2[0]), "r"((unsigned)w));
#endif
    return r;
}
__device__ __forceinline__ uint2 ROTF(const uint2 v, const int r) {
    if (r & 1) return make_uint2(rot32f(v.y, (r + 1) / 2), rot32f(v.x, (r - 1) / 2));
    return make_uint2(rot32f(v.x, r / 2), rot32f(v.y, r / 2));
}

#ifndef UNROLL_R
#define UNROLL_R 22  // misurato a cicli: 22 round srotolati = 64 registri, +2% (0.0150 hash/clk/SM)
#endif
#include "keccak_rounds.cuh"

// (pari, dispari) -> lane a 64 bit, e viceversa
__host__ __device__ inline u64 deinterleave(const uint2 v) {
    u64 r = 0;
    for (int i = 0; i < 32; i++) r |= (u64)((v.x >> i) & 1) << (2 * i) | (u64)((v.y >> i) & 1) << (2 * i + 1);
    return r;
}
static inline uint2 interleave(const u64 v) {
    unsigned e = 0, o = 0;
    for (int i = 0; i < 32; i++) { e |= (unsigned)((v >> (2 * i)) & 1) << i; o |= (unsigned)((v >> (2 * i + 1)) & 1) << i; }
    return make_uint2(e, o);
}

__device__ __forceinline__ void report(u64 nonce_lane, unsigned *count, u64 *out) {
    unsigned i = atomicAdd(count, 1u);
    if (i < 16) out[i] = nonce_lane;
}

// lane 0 dello stato finale (= primi 8 byte del digest) per lane 9 = L9
__device__ __forceinline__ uint2 keccak_a0(const uint2 L9) {
    uint2 a00, a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11, a12, a13, a14, a15, a16, a17,
        a18, a19, a20, a21, a22, a23, a24;
    uint2 b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11, b12, b13, b14, b15, b16, b17,
        b18, b19, b20, b21, b22, b23, b24;
    uint2 c0, c1, c2, c3, c4, d0, d1, d2, d3, d4;
    FIRST_ROUND
#if UNROLL_R == 22
    ROUNDS_1_22
#else
#if UNROLL_R == 2
#pragma unroll 1
    for (int r = 1; r < 21; r += 2) { ROUND(c_RC[r]) ROUND(c_RC[r + 1]) }
    ROUND(c_RC[21])
#else
#pragma unroll 1
    for (int r = 1; r < 22; r++) { ROUND(c_RC[r]) }
#endif
    // round 23 fuori dal loop: quando serve solo a0.x il compilatore elimina le meta inutili dei round 23-24
    ROUND(c_RC[22])
#endif
    LAST_ROUND_A0
    return a00;
}

// versione separata (non inline) per il caso raro: serve anche a0.y
__device__ __noinline__ uint2 keccak_a0_full(const uint2 L9) { return keccak_a0(L9); }

// Kernel ottimizzato: un hash per iterazione, lane 9 = base + gid + it*stride
#define MAX_SM_ID 512   // gli ID degli SM possono superare il numero di SM (chip con unita disattivate)
__device__ unsigned long long g_cyc_start[MAX_SM_ID], g_cyc_end[MAX_SM_ID];
__device__ __forceinline__ unsigned smid() {
    unsigned r;
    asm volatile("mov.u32 %0, %%smid;" : "=r"(r));
    return r;
}

template <bool TIMED>
__global__ void __launch_bounds__(256) mine_opt_t(u64 base, unsigned iters, unsigned *count, u64 *out) {
    if (TIMED && threadIdx.x == 0) atomicMin(&g_cyc_start[smid()], clock64());
    const u64 stride = (u64)gridDim.x * blockDim.x;
    u64 n = base + (u64)blockIdx.x * blockDim.x + threadIdx.x;
    for (unsigned it = 0; it < iters; it++, n += stride) {
        const uint2 L9 = make_uint2((unsigned)n, (unsigned)(n >> 32));
        if (c_T0.y == 0) {
            // target < 2^224 (caso reale): i primi 4 byte del digest = bit 0..31 della lane 0 = 16 bit bassi
            // della parola pari e della dispari. Si calcola solo la parola pari (il compilatore pota round 23-24);
            // 1 hash su 65536 passa e viene ricalcolato per intero.
            if ((keccak_a0(L9).x & 0xffffu) == 0) {
                const uint2 a0 = keccak_a0_full(L9);
                if (((a0.x | a0.y) & 0xffffu) == 0) report(n, count, out);
            }
        } else {   // target di test molto facili: confronto sui 64 bit alti
            const u64 lane = deinterleave(keccak_a0(L9));
            const unsigned hi = __byte_perm((unsigned)lane, 0, 0x0123), lo = __byte_perm((unsigned)(lane >> 32), 0, 0x0123);
            if (hi < c_T0.y || (hi == c_T0.y && lo <= c_T0.x)) report(n, count, out);
        }
    }
    if (TIMED) {
        __syncthreads();
        if (threadIdx.x == 0) atomicMax(&g_cyc_end[smid()], clock64());
    }
}
#define mine_opt mine_opt_t<false>

__global__ void debug_a0(u64 *out) {
    const uint2 a0 = keccak_a0(make_uint2(threadIdx.x, 0));   // contatore interleaved
    out[threadIdx.x] = deinterleave(a0);
}

__device__ __forceinline__ u64 bswap64(u64 v) {
    return ((u64)__byte_perm((unsigned)v, 0, 0x0123) << 32) | __byte_perm((unsigned)(v >> 32), 0, 0x0123);
}

// Kernel naive (riferimento): keccak-f generico a loop su uint64, come nelle implementazioni da libro
__global__ void mine_naive(u64 base, unsigned iters, unsigned *count, u64 *out, u64 T0) {
    const u64 stride = (u64)gridDim.x * blockDim.x;
    u64 n = base + (u64)blockIdx.x * blockDim.x + threadIdx.x;
    for (unsigned it = 0; it < iters; it++, n += stride) {
        u64 A[25], B[25], C[5], D[5];
        for (int i = 0; i < 25; i++) A[i] = i < 17 ? c_lanes[i] : 0;
        A[9] = n;
        for (int r = 0; r < 24; r++) {
            for (int x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
            for (int x = 0; x < 5; x++) {
                u64 c = C[(x + 1) % 5];
                D[x] = C[(x + 4) % 5] ^ ((c << 1) | (c >> 63));
            }
            for (int i = 0; i < 25; i++) {
                int x = i % 5, y = i / 5, k = d_RHO[i];
                u64 v = A[i] ^ D[x];
                B[y + 5 * ((2 * x + 3 * y) % 5)] = k ? (v << k) | (v >> (64 - k)) : v;
            }
            for (int i = 0; i < 25; i++) {
                int x = i % 5, y = i / 5;
                A[i] = B[i] ^ (~B[(x + 1) % 5 + 5 * y] & B[(x + 2) % 5 + 5 * y]);
            }
            A[0] ^= d_RC[r];
        }
        if (bswap64(A[0]) <= T0) report(n, count, out);
    }
}

// ---------------------------------------------------------------- host
struct Job {
    uint8_t msg[84];   // challenge | sender | nonce (byte 72..79 = lane 9, variabile)
    uint8_t target[32];
};

static bool parse_hex(const char *s, uint8_t *out, int nbytes) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    int len = (int)strlen(s);
    if (len == 0 || len > 2 * nbytes) return false;
    memset(out, 0, nbytes);
    // allineato a destra (big-endian): "0x1" -> ...0001
    for (int i = 0; i < len; i++) {
        char ch = s[len - 1 - i];
        int v = (ch >= '0' && ch <= '9') ? ch - '0' : (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10
              : (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10 : -1;
        if (v < 0) return false;
        out[nbytes - 1 - i / 2] |= (uint8_t)((i & 1) ? v << 4 : v);
    }
    return true;
}

static std::string hex(const uint8_t *p, int n) {
    static const char *H = "0123456789abcdef";
    std::string s = "0x";
    for (int i = 0; i < n; i++) { s += H[p[i] >> 4]; s += H[p[i] & 15]; }
    return s;
}

static inline uint2 U2(u64 v) { return make_uint2((unsigned)v, (unsigned)(v >> 32)); }
static inline uint2 I2(u64 v) { return interleave(v); }

// precalcolo round 1 e upload costanti
static void upload_job(const Job &job) {
    uint8_t blk[136] = {0};
    memcpy(blk, job.msg, 84);
    blk[84] ^= 0x01;
    blk[135] ^= 0x80;
    u64 S[25] = {0};
    for (int i = 0; i < 17; i++) memcpy(&S[i], blk + 8 * i, 8);
    S[9] = 0;
    u64 C[5], D[5];
    for (int x = 0; x < 5; x++) C[x] = S[x] ^ S[x + 5] ^ S[x + 10] ^ S[x + 15] ^ S[x + 20];
    for (int x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 1);
    uint2 hS[25], hB[25], hRC[24];
    memset(hB, 0, sizeof hB);
    for (int i = 0; i < 25; i++) {
        hS[i] = I2(S[i]);
        int x = i % 5, y = i / 5;
        if ((x == 1 || x == 2 || x == 4) && i != 9)
            hB[y + 5 * ((2 * x + 3 * y) % 5)] = I2(rotl64(S[i] ^ D[x], RHO[i]));
    }
    for (int r = 0; r < 24; r++) hRC[r] = I2(RC[r]);
    uint2 C4 = I2(C[4]), R1C1 = I2(rotl64(C[1], 1)), C2 = I2(C[2]), D4 = I2(D[4]);
    u64 T0 = 0;
    for (int i = 0; i < 8; i++) T0 = (T0 << 8) | job.target[i];
    uint2 hT0 = U2(T0);
    unsigned pw[32];
    for (int i = 0; i < 32; i++) pw[i] = 1u << i;
    CK(cudaMemcpyToSymbol(c_pow2, pw, sizeof pw));
    CK(cudaMemcpyToSymbol(c_S, hS, sizeof hS));
    CK(cudaMemcpyToSymbol(c_B, hB, sizeof hB));
    CK(cudaMemcpyToSymbol(c_C4, &C4, sizeof C4));
    CK(cudaMemcpyToSymbol(c_R1C1, &R1C1, sizeof R1C1));
    CK(cudaMemcpyToSymbol(c_C2, &C2, sizeof C2));
    CK(cudaMemcpyToSymbol(c_D4, &D4, sizeof D4));
    CK(cudaMemcpyToSymbol(c_RC, hRC, sizeof hRC));
    CK(cudaMemcpyToSymbol(c_T0, &hT0, sizeof hT0));
    CK(cudaMemcpyToSymbol(c_lanes, S, sizeof(u64) * 17));
    CK(cudaMemcpyToSymbol(d_RC, RC, sizeof RC));
    CK(cudaMemcpyToSymbol(d_RHO, RHO, sizeof RHO));
}

// digest completo su CPU, true se <= target
static bool check_lane(const Job &job, u64 lane9, uint8_t nonce[32], uint8_t digest[32]) {
    uint8_t m[84];
    memcpy(m, job.msg, 84);
    memcpy(m + 72, &lane9, 8);
    memcpy(nonce, m + 52, 32);
    keccak256_cpu(m, 84, digest);
    return memcmp(digest, job.target, 32) <= 0;
}

// counter = valore enumerato dalla GPU (forma interleaved della lane 9)
static bool check(const Job &job, u64 counter, uint8_t nonce[32], uint8_t digest[32]) {
    return check_lane(job, deinterleave(make_uint2((unsigned)counter, (unsigned)(counter >> 32))), nonce, digest);
}

// digest > floor(target/2)  <=>  target/digest == 1  (esattamente una reward guadagnata)
static bool earns_exactly_one(const uint8_t digest[32], const uint8_t target[32]) {
    uint8_t half[32];
    int carry = 0;
    for (int i = 0; i < 32; i++) { half[i] = (uint8_t)((target[i] >> 1) | (carry << 7)); carry = target[i] & 1; }
    return memcmp(digest, half, 32) > 0;
}

static void random_job(Job &job, std::mt19937_64 &rng) {
    for (int i = 0; i < 84; i++) job.msg[i] = (uint8_t)rng();
}

static void randomize_nonce(Job &job) {
    std::random_device entropy;
    for (int i = 52; i < 84; i++) job.msg[i] = (uint8_t)entropy();
    memset(job.msg + 72, 0, 8);
}

struct Gpu {
    unsigned *d_count;
    u64 *d_out;
    int sms;
    Gpu() {
        CK(cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync));   // attesa senza busy-wait: libera un core per il miner CPU
        CK(cudaSetDevice(0));
        cudaDeviceProp p;
        CK(cudaGetDeviceProperties(&p, 0));
        sms = p.multiProcessorCount;
        fprintf(stderr, "GPU: %s, %d SM, cc %d.%d\n", p.name, sms, p.major, p.minor);
        CK(cudaMalloc(&d_count, sizeof(unsigned)));
        CK(cudaMalloc(&d_out, 16 * sizeof(u64)));
        CK(cudaMemset(d_count, 0, sizeof(unsigned)));
    }
};

static double now_s() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// lancia per ~secs secondi e restituisce gli hash/s
static double run_rate(Gpu &g, bool naive, int tpb, int blocks, unsigned iters, double secs) {
    u64 base = 0, total = 0;
    const u64 per = (u64)blocks * tpb * iters;
    if (naive) mine_naive<<<blocks, tpb>>>(base, 1, g.d_count, g.d_out, 0);   // warm-up
    else mine_opt<<<blocks, tpb>>>(base, 1, g.d_count, g.d_out);
    CK(cudaDeviceSynchronize());
    double t0 = now_s(), t;
    do {
        if (naive) mine_naive<<<blocks, tpb>>>(base, iters, g.d_count, g.d_out, 0);
        else mine_opt<<<blocks, tpb>>>(base, iters, g.d_count, g.d_out);
        CK(cudaDeviceSynchronize());
        base += per;
        total += per;
        t = now_s();
    } while (t - t0 < secs);
    return total / (t - t0);
}

static int cmd_bench(Gpu &g, double secs) {
    Job job;
    std::mt19937_64 rng(42);
    random_job(job, rng);
    memset(job.target, 0, 32);   // target impossibile: misura solo throughput
    upload_job(job);
    printf("== naive (keccak-f generico, uint64, loop)\n");
    const double rn = run_rate(g, true, 256, g.sms * 8, 16, secs);
    printf("   256 tpb x %d blocchi : %8.1f MH/s\n", g.sms * 8, rn / 1e6);
    printf("== ottimizzato (bit-interleaved, theta fusa in LOP3, round 1/24 ridotti)\n");
    double best = 0;
    int bt = 0, bb = 0;
    for (int tpb : {128, 256}) {
        for (int bpsm : {4, 8, 16, 32}) {
            const int blocks = g.sms * bpsm;
            const unsigned iters = (unsigned)(100e6 / ((double)blocks * tpb)) + 1;   // ~100M hash per lancio
            const double r = run_rate(g, false, tpb, blocks, iters, secs / 2);
            printf("   %3d tpb x %4d blocchi (iters %4u): %8.1f MH/s\n", tpb, blocks, iters, r / 1e6);
            if (r > best) { best = r; bt = tpb; bb = bpsm; }
        }
    }
    printf("== migliore: tpb=%d bpsm=%d  %.1f MH/s  (speedup vs naive x%.2f)\n", bt, bb, best / 1e6, best / rn);
    printf("BEST %d %d %.0f\n", bt, bb, best);
    return 0;
}

static int cmd_selftest(Gpu &g) {
    std::mt19937_64 rng(7);
    int ok = 0, bad = 0;
    for (int round = 0; round < 4; round++) {
        Job job;
        random_job(job, rng);
        memset(job.msg + 72, 0, 8);
        memset(job.target, 0, 32);
        job.target[2] = 0x10;            // target ~2^236  ->  ~1 soluzione ogni 2^20 hash
        memset(job.target + 3, 0xff, 29);
        upload_job(job);
        CK(cudaMemset(g.d_count, 0, sizeof(unsigned)));
        const unsigned per = g.sms * 8 * 256;
        mine_opt<<<g.sms * 8, 256>>>(0, ((1u << 21) + per - 1) / per, g.d_count, g.d_out);   // copre >= 2^21 nonce
        CK(cudaDeviceSynchronize());
        unsigned cnt;
        u64 lanes[16];
        CK(cudaMemcpy(&cnt, g.d_count, sizeof cnt, cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(lanes, g.d_out, sizeof lanes, cudaMemcpyDeviceToHost));
        for (unsigned i = 0; i < cnt && i < 16; i++) {
            uint8_t nonce[32], digest[32];
            const bool v = check(job, lanes[i], nonce, digest);
            v ? ok++ : bad++;
            uint8_t m[84];
            memcpy(m, job.msg, 84);
            memcpy(m + 52, nonce, 32);
            // riga per verifica indipendente in Python: messaggio, digest, target
            printf("SOL %s %s %s %s\n", v ? "ok" : "BAD", hex(m, 84).c_str(), hex(digest, 32).c_str(),
                   hex(job.target, 32).c_str());
        }
        // controllo inverso su CPU: nessuna soluzione persa tra i primi 2^21 nonce (se il buffer non è saturo)
        if (cnt < 16) {
            int cpu_found = 0;
            for (u64 n = 0; n < (1u << 21); n++) {
                uint8_t nonce[32], digest[32];
                if (check(job, n, nonce, digest)) cpu_found++;
            }
            int gpu_found = 0;
            for (unsigned i = 0; i < cnt; i++) gpu_found += lanes[i] < (1u << 21);
            printf("job %d: GPU %d / CPU %d soluzioni nei primi 2^21 nonce\n", round, gpu_found, cpu_found);
            if (gpu_found != cpu_found) bad++;
        }
    }
    printf("SELFTEST %s: %d soluzioni corrette, %d errori\n", bad ? "FAIL" : "OK", ok, bad);
    return bad ? 1 : 0;
}

// stampa la soluzione se valida (e accettabile con --exact-one); true = trovata
static bool accept(const Job &job, bool exact_one, bool valid, const uint8_t nonce[32], const uint8_t digest[32]) {
    if (!valid) return false;                                   // falso positivo del prefiltro
    if (exact_one && !earns_exactly_one(digest, job.target)) {  // soluzione "forte" scartata su richiesta
        fprintf(stderr, "skip soluzione forte %s\n", hex(digest, 32).c_str());
        return false;
    }
    printf("FOUND %s %s\n", hex(nonce, 32).c_str(), hex(digest, 32).c_str());
    fflush(stdout);
    return true;
}

static int cmd_mine(Gpu &g, int argc, char **argv) {
    Job job;
    if (argc < 5 || !parse_hex(argv[2], job.msg, 32) || !parse_hex(argv[3], job.msg + 32, 20) ||
        !parse_hex(argv[4], job.target, 32)) {
        fprintf(stderr, "uso: mine <challenge 0x..32B> <sender 0x..20B> <target 0x..> [--exact-one] [--tpb N] [--bpsm N]"
                        " [--cpu-threads N] [--no-gpu] [--secs S]\n");
        return 2;
    }
    bool exact_one = false, gpu_on = true;
    int tpb = 128, bpsm = 16;   // migliore configurazione dal bench su RTX 4060 Laptop
    int cpu_threads = 0;
    double max_secs = 0;        // 0 = finche non trova
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--exact-one")) exact_one = true;
        else if (!strcmp(argv[i], "--no-gpu")) gpu_on = false;
        else if (!strcmp(argv[i], "--tpb") && i + 1 < argc) tpb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bpsm") && i + 1 < argc) bpsm = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cpu-threads") && i + 1 < argc) cpu_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) max_secs = atof(argv[++i]);
    }
    if (tpb > 256) tpb = 256;
    randomize_nonce(job);
    upload_job(job);
    u64 T0 = 0;
    for (int i = 0; i < 8; i++) T0 = (T0 << 8) | job.target[i];
    CpuPool pool;
    pool.start(cpu_threads, job.msg, T0);
    set_current_thread_priority_high();   // il thread che alimenta la GPU non deve aspettare i thread CPU

    // Pipeline a due slot: mentre la GPU esegue il lancio k+1 l'host legge i risultati del lancio k,
    // quindi la GPU non resta mai ferma tra un lancio e il successivo.
    const int blocks = g.sms * bpsm;
    unsigned *d_cnt[2], *h_cnt[2];
    u64 *d_res[2], *h_res[2];
    cudaEvent_t ev[2];
    for (int k = 0; k < 2; k++) {
        CK(cudaMalloc(&d_cnt[k], sizeof(unsigned)));
        CK(cudaMalloc(&d_res[k], 16 * sizeof(u64)));
        CK(cudaHostAlloc(&h_cnt[k], sizeof(unsigned), cudaHostAllocDefault));
        CK(cudaHostAlloc(&h_res[k], 16 * sizeof(u64), cudaHostAllocDefault));
        CK(cudaEventCreateWithFlags(&ev[k], cudaEventBlockingSync | cudaEventDisableTiming));
    }
    unsigned iters = 16;
    u64 base = 0, gpu_total = 0;
    auto launch = [&](int k) {
        CK(cudaMemsetAsync(d_cnt[k], 0, sizeof(unsigned)));
        mine_opt<<<blocks, tpb>>>(base, iters, d_cnt[k], d_res[k]);
        CK(cudaMemcpyAsync(h_cnt[k], d_cnt[k], sizeof(unsigned), cudaMemcpyDeviceToHost));
        CK(cudaMemcpyAsync(h_res[k], d_res[k], 16 * sizeof(u64), cudaMemcpyDeviceToHost));
        CK(cudaEventRecord(ev[k]));
        base += (u64)blocks * tpb * iters;
    };
    // attende il lancio nello slot k e verifica i candidati; true = soluzione stampata
    auto harvest = [&](int k) {
        CK(cudaEventSynchronize(ev[k]));
        gpu_total += (u64)blocks * tpb * iters;
        for (unsigned i = 0; i < *h_cnt[k] && i < 16; i++) {
            uint8_t nonce[32], digest[32];
            const bool valid = check(job, h_res[k][i], nonce, digest);
            if (accept(job, exact_one, valid, nonce, digest)) return true;
        }
        return false;
    };
    if (gpu_on) {
        // calibrazione: lanci da ~100 ms (watchdog WDDM, restart rapido al cambio challenge)
        for (;;) {
            const double ts = now_s();
            launch(0);
            if (harvest(0)) return 0;
            if (now_s() - ts >= 0.06 || iters >= (1u << 20)) break;
            iters *= 2;
        }
        launch(0);
    }
    const double t0 = now_s();
    double last = t0;
    gpu_total = 0;
    int cur = 0;
    for (;;) {
        if (gpu_on) {
            launch(cur ^ 1);                 // in coda dietro al lancio corrente
            if (harvest(cur)) return 0;
            cur ^= 1;
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (const u64 lane9 = pool.sh.found_lane9.load()) {   // candidato dai thread CPU
            uint8_t nonce[32], digest[32];
            const bool valid = check_lane(job, lane9, nonce, digest);
            if (accept(job, exact_one, valid, nonce, digest)) return 0;
            pool.sh.found_lane9 = 0;
        }
        const double t = now_s();
        const bool done = max_secs > 0 && t - t0 >= max_secs;
        if (t - last >= 5.0 || done) {
            const u64 cpu_total = pool.sh.hashes.load(), total = gpu_total + cpu_total;
            const double el = t - t0;
            printf("STATUS %.1f %llu %.0f %.1f %.1f\n", total / el / 1e6, total, el, gpu_total / el / 1e6,
                   cpu_total / el / 1e6);
            fflush(stdout);
            last = t;
        }
        if (done) return 0;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "uso: keccak_miner bench [s] | selftest | mine <challenge> <sender> <target> [--exact-one]\n");
        return 2;
    }
    Gpu g;
    const std::string cmd = argv[1];
    if (cmd == "bench") return cmd_bench(g, argc > 2 ? atof(argv[2]) : 6.0);
    if (cmd == "selftest") return cmd_selftest(g);
    if (cmd == "cyc") {   // hash per clock per SM, indipendente da frequenza e temperatura: cyc [lanci] [tpb] [bpsm]
        Job job;
        std::mt19937_64 rng(42);
        random_job(job, rng);
        memset(job.target, 0, 32);
        upload_job(job);
        const int launches = argc > 2 ? atoi(argv[2]) : 20, tpb = argc > 3 ? atoi(argv[3]) : 128;
        const int blocks = g.sms * (argc > 4 ? atoi(argv[4]) : 16);
        const unsigned iters = (unsigned)(100e6 / ((double)blocks * tpb)) + 1;
        mine_opt_t<true><<<blocks, tpb>>>(0, 1, g.d_count, g.d_out);   // warm-up
        CK(cudaDeviceSynchronize());
        double cyc = 0, hashes = 0, wall = 0;
        unsigned long long st[MAX_SM_ID], en[MAX_SM_ID];
        for (int l = 0; l < launches; l++) {
            for (int i = 0; i < MAX_SM_ID; i++) { st[i] = ~0ULL; en[i] = 0; }
            CK(cudaMemcpyToSymbol(g_cyc_start, st, sizeof st));
            CK(cudaMemcpyToSymbol(g_cyc_end, en, sizeof en));
            const double ts = now_s();
            mine_opt_t<true><<<blocks, tpb>>>((u64)l << 40, iters, g.d_count, g.d_out);
            CK(cudaDeviceSynchronize());
            wall += now_s() - ts;
            CK(cudaMemcpyFromSymbol(st, g_cyc_start, sizeof st));
            CK(cudaMemcpyFromSymbol(en, g_cyc_end, sizeof en));
            for (int i = 0; i < MAX_SM_ID; i++) if (en[i]) cyc += (double)(en[i] - st[i]);
            hashes += (double)blocks * tpb * iters;
        }
        const double hpc = hashes / cyc;
        printf("%.5f hash/clk/SM   reale %.1f MH/s a %.0f MHz effettivi   (%d SM)\n", hpc, hashes / wall / 1e6,
               cyc / g.sms / wall / 1e6, g.sms);
        return 0;
    }
    if (cmd == "quick") {   // misura rapida a configurazione fissa: quick <secondi> <tpb> <bpsm>
        Job job;
        std::mt19937_64 rng(42);
        random_job(job, rng);
        memset(job.target, 0, 32);
        upload_job(job);
        const int tpb = argc > 3 ? atoi(argv[3]) : 128, blocks = g.sms * (argc > 4 ? atoi(argv[4]) : 8);
        const double r = run_rate(g, false, tpb, blocks, (unsigned)(100e6 / ((double)blocks * tpb)) + 1,
                                  argc > 2 ? atof(argv[2]) : 3.0);
        printf("%.1f\n", r / 1e6);
        return 0;
    }
    if (cmd == "debug") {
        Job job;
        std::mt19937_64 rng(7);
        random_job(job, rng);
        memset(job.msg + 72, 0, 8);
        memset(job.target, 0, 32);
        upload_job(job);
        debug_a0<<<1, 4>>>(g.d_out);
        u64 gpu[4];
        CK(cudaMemcpy(gpu, g.d_out, sizeof gpu, cudaMemcpyDeviceToHost));
        for (int i = 0; i < 4; i++) {
            uint8_t nonce[32], digest[32];
            check(job, (u64)i, nonce, digest);   // stesso contatore -> stessa lane
            u64 cpu;
            memcpy(&cpu, digest, 8);
            printf("n=%d gpu=%016llx cpu=%016llx\n", i, gpu[i], cpu);
        }
        return 0;
    }
    if (cmd == "mine") return cmd_mine(g, argc, argv);
    fprintf(stderr, "comando sconosciuto\n");
    return 2;
}