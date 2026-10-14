"""Legge lo stato di mining dei 4 Seasonal Tokens su Ethereum L1."""
import os, sys, time
from web3 import Web3

RPC = os.environ.get("ETH_RPC", "https://eth.drpc.org")
TOKENS = {
    "SPRING": "0xf04af3f4e4929f7cd25a751e6149a3318373d4fe",
    "SUMMER": "0x4d4f3715050571a447fffa2cd4cf091c7014ca5c",
    "AUTUMN": "0x4c3bae16c79c30eeb1004fb03c878d89695e3a99",
    "WINTER": "0xccba0b2bc4babe4cbfb6bd2f1edc2a9e86b7845f",
}
ABI = [
    {"name": n, "type": "function", "stateMutability": "view", "inputs": i, "outputs": [{"type": o}]}
    for n, i, o in [
        ("getChallengeNumber", [], "bytes32"), ("getMiningTarget", [], "uint256"),
        ("getMiningDifficulty", [], "uint256"), ("getMiningReward", [], "uint256"),
        ("lastRewardBlockTime", [], "uint256"), ("maxNumberOfRewardsPerMint", [], "uint256"),
        ("tokensMinted", [], "uint256"), ("owner", [], "address"),
        ("getNumberOfRewardsAvailable", [{"type": "uint256", "name": "t"}], "uint256"),
    ]
] + [{"name": "Mint", "type": "event", "anonymous": False, "inputs": [
    {"indexed": True, "name": "from", "type": "address"}, {"indexed": False, "name": "rewardAmount", "type": "uint256"},
    {"indexed": False, "name": "epochCount", "type": "uint256"}, {"indexed": False, "name": "newChallengeNumber", "type": "bytes32"}]}]

def w3():
    return Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 30}))

def contract(w, sym):
    return w.eth.contract(address=Web3.to_checksum_address(TOKENS[sym]), abi=ABI)

def read_state(w, sym):
    c = contract(w, sym)
    f = c.functions
    now = w.eth.get_block("latest")["timestamp"]
    return dict(
        challenge=f.getChallengeNumber().call(), target=f.getMiningTarget().call(),
        difficulty=f.getMiningDifficulty().call(), reward=f.getMiningReward().call(),
        last=f.lastRewardBlockTime().call(), maxper=f.maxNumberOfRewardsPerMint().call(),
        available=f.getNumberOfRewardsAvailable(now).call(), owner=f.owner().call(), now=now)

if __name__ == "__main__":
    w = w3()
    head = w.eth.block_number
    for sym in TOKENS:
        s = read_state(w, sym)
        print(f"== {sym}  owner={s['owner']}")
        print(f"   challenge = 0x{s['challenge'].hex()}")
        print(f"   target    = {hex(s['target'])} (~2^{s['target'].bit_length()})")
        print(f"   difficulty= {s['difficulty']:.3e}   reward={s['reward']/1e18}   maxPerMint={s['maxper']}  available_now={s['available']}")
        print(f"   last mint {(s['now']-s['last'])/60:.1f} min ago")
        if "--history" in sys.argv:
            c = contract(w, sym)
            logs, step = [], 5_000
            for b in range(head - 300_000, head, step):  # ~42 giorni
                logs += c.events.Mint().get_logs(from_block=b, to_block=min(b + step - 1, head))
            prev = None
            for lg in logs[-10:]:
                ts = w.eth.get_block(lg["blockNumber"])["timestamp"]
                n = lg["args"]["rewardAmount"] / s["reward"] if s["reward"] else 0
                gap = f"{(ts-prev)/60:7.1f}m" if prev else "       "
                print(f"     blk {lg['blockNumber']} gap {gap} from {lg['args']['from'][:10]}.. rewards={n:.1f}")
                prev = ts
            print(f"   mints in last 300k blocks (~42 days): {len(logs)}")
