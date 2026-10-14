"""Mining onesto di un Seasonal Token: mint(nonce) con keccak256(challenge | sender | nonce) <= target.

Esempi:
  python miner.py --verify-formula                 # verifica on-chain la formula del digest (nessuna tx)
  python miner.py --address 0xTUO --token auto     # mina il token con difficolta minima, solo simulazione
  python miner.py --address 0xTUO --test-bits 230  # prova tutta la pipeline con un target finto e facile
  set PRIVATE_KEY=...  &&  python miner.py --address 0xTUO --send   # invia davvero la tx

La chiave privata viene letta SOLO dalla variabile di ambiente PRIVATE_KEY e mai stampata.
"""
import argparse
import os
import queue
import random
import subprocess
import sys
import threading
import time

from eth_hash.auto import keccak
from web3 import Web3
from web3.exceptions import ContractLogicError

from state import ABI, RPC, TOKENS

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, "keccak_miner.exe")
# endpoint MEV Blocker che non include tx destinate al revert: se qualcun altro mina prima di noi
# e il challenge cambia, non paghiamo gas per una tx fallita
SEND_RPC = os.environ.get("SEND_RPC", "https://rpc.mevblocker.io/noreverts")
MINT_ABI = ABI + [
    {"name": "mint", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "nonce", "type": "uint256"}], "outputs": [{"type": "bool"}]},
    {"name": "mint", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "_nonce", "type": "uint256"}, {"name": "_challengeDigest", "type": "bytes32"}],
     "outputs": [{"type": "bool"}]},
]
POLL_S = 12  # un blocco Ethereum


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def digest_of(challenge: bytes, sender: str, nonce: int) -> bytes:
    return keccak(challenge + bytes.fromhex(sender[2:]) + nonce.to_bytes(32, "big"))


class Token:
    def __init__(self, w3, sym):
        self.sym = sym
        self.c = w3.eth.contract(address=Web3.to_checksum_address(TOKENS[sym]), abi=MINT_ABI)
        self.w3 = w3

    def challenge(self) -> bytes:
        return bytes(self.c.functions.getChallengeNumber().call())

    def target(self) -> int:
        return self.c.functions.getMiningTarget().call()

    def available(self) -> int:
        return self.c.functions.getNumberOfRewardsAvailable(self.w3.eth.get_block("latest")["timestamp"]).call()

    def simulate(self, sender, nonce):
        """eth_call di mint(nonce) come se lo inviasse sender: (ok, motivo)."""
        try:
            self.c.functions.mint(nonce).call({"from": sender})
            return True, "ok"
        except ContractLogicError as err:
            return False, str(err)


def pick_token(w3, sym):
    if sym != "auto":
        return Token(w3, sym)
    diffs = {s: Token(w3, s).c.functions.getMiningDifficulty().call() for s in TOKENS}
    for s, d in diffs.items():
        log(f"{s}: difficolta {d:.3e}")
    best = min(diffs, key=diffs.get)
    log(f"scelto {best} (difficolta minima)")
    return Token(w3, best)


def verify_formula(w3):
    """Prova on-chain che la nostra formula del digest coincide con quella del contratto:
    mint(nonce, digest) col digest giusto deve fallire per "larger than mining target"
    (controllo del digest superato), non per "does not match"."""
    sender = "0x000000000000000000000000000000000000dEaD"
    for sym in TOKENS:
        t = Token(w3, sym)
        nonce = random.getrandbits(256)
        d = digest_of(t.challenge(), sender, nonce)
        try:
            t.c.functions.mint(nonce, d).call({"from": sender})
            log(f"{sym}: inatteso, la call non ha fatto revert")
        except ContractLogicError as err:
            ok = "larger than mining target" in str(err)
            log(f"{sym}: " + ("FORMULA OK" if ok else "FORMULA ERRATA") + f"  (revert: {err})")


def send_mint(w3, token, sender, nonce):
    from eth_account import Account
    key = os.environ.get("PRIVATE_KEY")
    if not key:
        log("PRIVATE_KEY non impostata: niente invio")
        return
    acct = Account.from_key(key)
    if acct.address.lower() != sender.lower():
        log("PRIVATE_KEY non corrisponde a --address: il digest dipende da msg.sender, invio annullato")
        return
    base = w3.eth.get_block("latest")["baseFeePerGas"]
    prio = w3.to_wei(float(os.environ.get("PRIORITY_GWEI", "0.5")), "gwei")
    fn = token.c.functions.mint(nonce)
    gas = fn.estimate_gas({"from": sender})
    tx = fn.build_transaction({
        "from": sender, "nonce": w3.eth.get_transaction_count(sender), "chainId": 1,
        "gas": int(gas * 1.25), "maxPriorityFeePerGas": prio, "maxFeePerGas": 2 * base + prio,
    })
    signed = acct.sign_transaction(tx)
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    sw3 = Web3(Web3.HTTPProvider(SEND_RPC, request_kwargs={"timeout": 30}))
    txh = Web3.to_hex(sw3.eth.send_raw_transaction(raw))
    log(f"tx inviata via {SEND_RPC}: {txh}  (gas stimato {gas})")
    rc = w3.eth.wait_for_transaction_receipt(txh, timeout=600, poll_latency=6)
    log("receipt: status=%s blocco=%s gasUsed=%s" % (rc["status"], rc["blockNumber"], rc["gasUsed"]))


def run_gpu(args, challenge, sender, target):
    cmd = [EXE, "mine", "0x" + challenge.hex(), sender, hex(target), "--tpb", str(args.tpb), "--bpsm", str(args.bpsm)]
    if args.exact_one:
        cmd.append("--exact-one")
    if args.cpu_threads:
        cmd += ["--cpu-threads", str(args.cpu_threads)]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    q = queue.Queue()
    threading.Thread(target=lambda: [q.put(l.strip()) for l in p.stdout], daemon=True).start()
    return p, q


def mine(args, w3):
    token = pick_token(w3, args.token)
    sender = Web3.to_checksum_address(args.address)
    while True:
        challenge = token.challenge()
        real_target = token.target()
        target = (1 << args.test_bits) if args.test_bits else real_target
        diff = (2**256 - 1) // target
        log(f"{token.sym} challenge 0x{challenge.hex()[:16]}..  difficolta {diff:.3e}"
            + ("  [TARGET DI TEST]" if args.test_bits else ""))
        p, q = run_gpu(args, challenge, sender, target)
        t_check = time.time()
        restart = False
        while not restart:
            try:
                line = q.get(timeout=POLL_S)
            except queue.Empty:
                line = ""
            if not line and p.poll() is not None and q.empty():
                log("processo GPU terminato inaspettatamente")
                return 1
            if line.startswith("STATUS"):
                parts = line.split()   # STATUS totale hash secondi [gpu cpu]
                rate, tot = float(parts[1]) * 1e6, parts[2]
                log(f"{rate / 1e6:7.1f} MH/s  {int(tot) / 1e12:8.3f} TH provati  "
                    f"tempo medio atteso per soluzione {diff / rate / 3600:.1f} h")
            elif line.startswith("FOUND"):
                _, nonce_hex, dig_hex = line.split()
                nonce = int(nonce_hex, 16)
                d = digest_of(challenge, sender, nonce)
                assert d.hex() == dig_hex[2:], "digest GPU != digest Python"
                dv = int.from_bytes(d, "big")
                assert dv <= target
                earned = real_target // dv if dv else 0
                avail = token.available()
                with open(os.path.join(HERE, "solutions.log"), "a") as f:
                    print(time.ctime(), token.sym, f"challenge=0x{challenge.hex()}", f"sender={sender}",
                          f"nonce={nonce_hex}", f"digest={dig_hex}", file=f)
                log(f"SOLUZIONE nonce={nonce_hex}")
                log(f"  digest={dig_hex}  rewards={min(earned, avail)} (earned {earned}, disponibili {avail})")
                if token.challenge() != challenge:
                    log("  challenge cambiato nel frattempo: soluzione scaduta, riparto")
                    restart = True
                    continue
                ok, why = token.simulate(sender, nonce)
                log("  simulazione eth_call mint(nonce): " + ("OK" if ok else "REVERT " + why))
                if args.fleet:
                    # riga canonica letta dal supervisore sul PC; nessun invio dall istanza (niente chiave privata)
                    if ok:
                        print(f"FLEETSOL {token.sym} 0x{challenge.hex()} {nonce_hex} {dig_hex} earned={earned}", flush=True)
                    restart = True   # continua a minare sul prossimo challenge, non terminare
                    continue
                if ok and args.send:
                    send_mint(w3, token, sender, nonce)
                elif ok:
                    log("  pronta: rilancia con --send (e PRIVATE_KEY) oppure chiama mint(nonce) dal tuo wallet SUBITO")
                p.kill()
                return 0
            if time.time() - t_check >= POLL_S:
                t_check = time.time()
                try:
                    if token.challenge() != challenge:
                        log("challenge cambiato (qualcuno ha mintato): riavvio GPU sul nuovo challenge")
                        restart = True
                except Exception as err:  # RPC momentaneamente giu: continuo a minare
                    log(f"RPC: {err}")
        p.kill()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token", default="auto", choices=["auto", *TOKENS])
    ap.add_argument("--address", help="address che chiamera mint (msg.sender)")
    ap.add_argument("--send", action="store_true", help="invia davvero la tx (richiede PRIVATE_KEY)")
    ap.add_argument("--fleet", action="store_true", help="modalita istanza remota: stampa FLEETSOL e continua, mai invio")
    ap.add_argument("--exact-one", action="store_true",
                    help="accetta solo digest in (target/2, target] -> esattamente 1 reward (raddoppia il tempo atteso)")
    ap.add_argument("--test-bits", type=int, default=0, help="target finto 2^N per provare la pipeline (es. 230)")
    ap.add_argument("--verify-formula", action="store_true")
    ap.add_argument("--cpu-threads", type=int, default=0,
                    help="thread CPU AVX2 in aggiunta alla GPU (misurato: circa +3%% a caldo, ma piu calore)")
    ap.add_argument("--tpb", type=int, default=128)
    ap.add_argument("--bpsm", type=int, default=16)
    args = ap.parse_args()
    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 30}))
    if args.verify_formula:
        return verify_formula(w3)
    if not args.address:
        ap.error("--address obbligatorio")
    return mine(args, w3)


if __name__ == "__main__":
    sys.exit(main() or 0)
