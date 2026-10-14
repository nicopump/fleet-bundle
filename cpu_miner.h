// Miner CPU AVX2 da affiancare alla GPU: ogni thread calcola 4 Keccak per istruzione.
#pragma once
#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

struct CpuShared {
    std::atomic<bool> stop{false};
    std::atomic<unsigned long long> hashes{0};
    std::atomic<unsigned long long> found_lane9{0};   // != 0: candidato (lane 9 reale, bit 63 sempre 1)
};

// msg = challenge | sender | nonce (84 byte); T0 = 64 bit alti del target.
// Il thread tid enumera la lane 9 in [2^63 + tid * 2^52, ...): disgiunto dallo spazio della GPU.
void cpu_worker(const uint8_t *msg, unsigned long long T0, int tid, CpuShared *sh);

// priorita alta per il thread corrente (quello che alimenta la GPU)
void set_current_thread_priority_high();

// avvia/ferma i thread CPU (join automatico in uscita)
struct CpuPool {
    CpuShared sh;
    std::vector<std::thread> th;
    void start(int n, const uint8_t *msg, unsigned long long T0) {
        for (int i = 0; i < n; i++) th.emplace_back(cpu_worker, msg, T0, i, &sh);
    }
    ~CpuPool() {
        sh.stop = true;
        for (auto &t : th) t.join();
    }
};
