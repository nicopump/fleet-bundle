# Seasonal Tokens: miner GPU (RTX 4060)

## File
| file | cosa fa |
|---|---|
| `state.py` | legge stato on-chain dei 4 token (`python state.py`) |
| `keccak_miner.cu` + `gen_rounds.py` | miner CUDA (`build.bat` per compilare) |
| `miner.py` | orchestratore: stato -> GPU -> verifica -> `eth_call` -> invio opzionale |

## Uso
```
build.bat
keccak_miner.exe selftest          # GPU vs CPU vs eth_hash
keccak_miner.exe bench 6           # benchmark
python miner.py --verify-formula   # conferma on-chain della formula del digest
python miner.py --address 0xTUO    # mina il token con difficolta minima (solo simulazione)
```
Per inviare davvero: impostare `PRIVATE_KEY` nell'ambiente e aggiungere `--send`.
L'invio passa da `rpc.mevblocker.io/noreverts`: se il challenge cambia prima, la tx non viene inclusa e non si paga gas.

## Benchmark (RTX 4060 Laptop, 24 SM)
Metrica principale: hash per clock per SM (misurata con clock64 nel kernel), indipendente da frequenza e
temperatura: `keccak_miner.exe cyc`. MH/s = valore x 24 SM x clock.

| kernel | hash/clk/SM | MH/s @2295 MHz (sostenuto) | MH/s @2640 MHz (boost) |
|---|---|---|---|
| v1: uint2 + SHF | ~0.0122 | ~660 | ~760 |
| v2: + bit-interleaving | ~0.0137 | ~750 | ~860 |
| v3: + theta fusa in LOP3 | ~0.0147 | ~810 | ~930 |
| **v4: + 22 round srotolati (64 registri), round 23-24 potati** | **~0.0150** | **~828** | **~952** |

Il kernel esegue ~60 istruzioni ALU per clock per SM contro un picco misurato di 61.6: ~98% del limite fisico.

Provato e scartato (misura a cicli): rotazioni sulla pipe FMA (IMAD.SHL+IMAD.HI: da -5% a -14%),
configurazioni di lancio diverse (tutte entro 0.5%).

Miner CPU AVX2 (`--cpu-threads N`): ~83 MH/s da solo, ma insieme alla GPU il calore condiviso porta il
guadagno netto a circa +3%.

## RTX 5090 (HyperAI, misurato 2026-10-04, dettagli in bench_5090.txt)
- LOP3 e SHF: 63.6 istruzioni/clk/SM, come Ada: su Blackwell consumer **non raddoppiano**.
- Kernel: 0.0163 hash/clk/SM (98% del picco della pipe), 7.7 GH/s a 2776 MHz.
- Sostenuto 180 s: **7.61 GH/s** a 2737 MHz, 536 W, 81 C (limite di potenza appena toccato).
- SPRING (difficolta 1.108e14): ~4.0 h in media per soluzione.
- Build Linux: `./build.sh` (rileva sm_120), benchmark completo: `./cloud_bench.sh [secondi]`.

## Ricerca ottimizzazioni (2026-10-04)
26 proposte da 7 lenti, 12 verificate con misure sulla 4060 (i microbench delle pipe coincidono con la 5090 entro il 3%).
- Il kernel e' al minimo algebrico (122 LOP3 + 52 SHF per round) e al ~99.6% del tetto della pipe ALU.
- Spostare rotazioni sulla pipe IMAD peggiora sempre (da -0.6% a -13%): IMAD.HI va a meta' rate e la
  co-emissione con LOP3 e' solo del 50-60%. Stessa cosa con 2 nonce per thread.
- PRMT gira sulla stessa pipe di LOP3; complementazione delle lane, potatura extra, bit-slicing: nessun guadagno.
- Margini residui: ~+0.5% dal codice, +1-2.5% dal punto di lavoro di potenza/clock se l'host lo consente.

## Campagna RTX 5090 (2026-10-05, log in bench/)
Misure a cicli sulla 5090 (sm_120), ognuna ripetuta 3 volte, correttezza OK su tutte le varianti:
| Variante | hash/clk/SM |
|---|---|
| Kernel attuale (22 round srotolati), 256 thread x 8 blocchi | **0.01634** (migliore) |
| Kernel attuale, 128 x 16 | 0.01631 |
| Round in loop / a coppie | 0.01610 / 0.01616 |
| Offload rotazioni su IMAD, ROT_PRIM 1 / 2, 8 rotazioni | 0.01623 / 0.01622 |
| Offload rotazioni su IMAD, ROT_PRIM 1 / 2, 20 rotazioni | 0.01609 / 0.01604 |
| Offload rotazioni su IMAD, ROT_PRIM 0, 20 rotazioni | 0.01533 |

- Co-mining CPU (15 thread AVX2 sul server): +1% netto.
- Clock e potenza non regolabili nel container HyperAI ("current user does not have permission to change clocks").
- **Prova sostenuta 10 minuti** (256x8 + 15 thread CPU): **7.82 GH/s** (GPU 7.69 + CPU 0.13), 4.69e12 hash,
  2767 MHz costanti, 573 W (limite 575 W), 81 C, ventole 89%.
- Script: `max_5090.sh` (campagna completa), `sustained.sh [secondi]` (prova sostenuta).

## Flotta multi-GPU su Vast.ai (cartella fleet/)
Sistema per minare in cloud a hashrate obiettivo e minimo costo: ottimizzatore della combo piu economica
(focus 5090 / PRO 6000 WS/S), bootstrap istanze con autotest, supervisore che noleggia/sostituisce e firma
le soluzioni sul PC. La chiave del wallet non entra mai in una istanza. Dettagli e comandi in fleet/README.md.
Default SIMULAZIONE; con --live noleggia davvero. Verificato in simulazione sui dati Vast live.

