#include "cpu_miner.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#define BSWAP64(x) _byteswap_uint64(x)
#else
#define BSWAP64(x) __builtin_bswap64(x)
#endif
#include <immintrin.h>
#include <cstdlib>
#include <cstring>

#include "cpu_rounds.h"

typedef unsigned long long u64;

static const u64 RCC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};

#define XV(a, b) _mm256_xor_si256((a), (b))

// rotazione a sinistra di 4 lane da 64 bit; 8 e 56 sono rotazioni di byte (un solo shuffle)
template <int N>
static inline __m256i rol(__m256i x) {
    if constexpr (N == 1)
        return _mm256_or_si256(_mm256_add_epi64(x, x), _mm256_srli_epi64(x, 63));
    else if constexpr (N == 8)
        return _mm256_shuffle_epi8(x, _mm256_setr_epi8(7, 0, 1, 2, 3, 4, 5, 6, 15, 8, 9, 10, 11, 12, 13, 14,
                                                       7, 0, 1, 2, 3, 4, 5, 6, 15, 8, 9, 10, 11, 12, 13, 14));
    else if constexpr (N == 56)
        return _mm256_shuffle_epi8(x, _mm256_setr_epi8(1, 2, 3, 4, 5, 6, 7, 0, 9, 10, 11, 12, 13, 14, 15, 8,
                                                       1, 2, 3, 4, 5, 6, 7, 0, 9, 10, 11, 12, 13, 14, 15, 8));
    else
        return _mm256_or_si256(_mm256_slli_epi64(x, N), _mm256_srli_epi64(x, 64 - N));
}

#ifdef _WIN32
void set_current_thread_priority_high() { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST); }
static void set_worker_priority_low() { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL); }
#else
// su Linux alzare la priorita richiede privilegi: si lascia fare allo scheduler
void set_current_thread_priority_high() {}
static void set_worker_priority_low() {}
#endif

void cpu_worker(const uint8_t *msg, u64 T0, int tid, CpuShared *sh) {
    set_worker_priority_low();   // la GPU ha la precedenza
    uint8_t blk[136] = {0};
    memcpy(blk, msg, 84);
    blk[84] ^= 0x01;
    blk[135] ^= 0x80;
    u64 S[17];
    for (int i = 0; i < 17; i++) memcpy(&S[i], blk + 8 * i, 8);
    u64 n = (1ULL << 63) | ((u64)tid << 52);
    const __m256i z = _mm256_setzero_si256();
    while (!sh->stop.load(std::memory_order_relaxed)) {
        for (int it = 0; it < 8192; it++, n += 4) {
            __m256i a00 = _mm256_set1_epi64x(S[0]), a01 = _mm256_set1_epi64x(S[1]), a02 = _mm256_set1_epi64x(S[2]),
                    a03 = _mm256_set1_epi64x(S[3]), a04 = _mm256_set1_epi64x(S[4]), a05 = _mm256_set1_epi64x(S[5]),
                    a06 = _mm256_set1_epi64x(S[6]), a07 = _mm256_set1_epi64x(S[7]), a08 = _mm256_set1_epi64x(S[8]),
                    a09 = _mm256_set_epi64x(n + 3, n + 2, n + 1, n), a10 = _mm256_set1_epi64x(S[10]),
                    a11 = z, a12 = z, a13 = z, a14 = z, a15 = z, a16 = _mm256_set1_epi64x(S[16]),
                    a17 = z, a18 = z, a19 = z, a20 = z, a21 = z, a22 = z, a23 = z, a24 = z;
            __m256i b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11, b12, b13, b14, b15, b16, b17,
                b18, b19, b20, b21, b22, b23, b24, c0, c1, c2, c3, c4, d0, d1, d2, d3, d4;
            for (int r = 0; r < 24; r++) {
                const u64 rc = RCC[r];
                CPU_ROUND(rc)
            }
            alignas(32) u64 v[4];
            _mm256_store_si256((__m256i *)v, a00);
            for (int k = 0; k < 4; k++) {
                if (BSWAP64(v[k]) <= T0) {   // 64 bit alti del digest; verifica completa nel thread principale
                    u64 expected = 0;
                    sh->found_lane9.compare_exchange_strong(expected, n + k);
                }
            }
        }
        sh->hashes.fetch_add(8192 * 4, std::memory_order_relaxed);
    }
}
