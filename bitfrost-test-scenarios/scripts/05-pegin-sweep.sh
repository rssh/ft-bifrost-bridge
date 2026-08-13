#!/usr/bin/env bash
# Scenario 5 — a depositor-built ONE-KEY BEACON peg-in, swept into the treasury.
#
# The round trip WI-073/WI-074 both deferred: the 35-byte beacon `"BFR" || Q_auth`
# leaves the depositor tool, is minted as a PegInRequest on Cardano, and the
# Treasury Movement SPENDS the deposit on Bitcoin. That last spend is the whole
# point. Everything before it — beacon layout, parsing, address derivation — is
# already covered by unit tests on both sides; what no test can reach is whether
# the taproot tweak the sweeper computes from the beacon's Q_auth actually
# matches the output key the depositor paid to. If the refund leaf carried the
# wrong key, this is where bitcoind rejects the signature.
#
# It is also the first scenario to stand up a WHOLE bridge: `binocular init` +
# `deploy-bridge` (WI-068 genesis — Config, singleton, and the registry/ban/
# treasury roots in two txs).
#
# NOT a 4-SPO scenario. `sweep-pegins` derives Y_51 from the deterministic demo
# DKG and holds every share in-process, so the peg-in tree is exercised without
# the roster scenario 1 builds. Those are separate claims; this file proves one.
. "$(dirname "$0")/00-lib.sh"
check_pins

# Longer epochs than the DKG scenarios, and the number is bounded from BOTH sides.
#
# From below: a transaction is unsubmittable if its validity END lies past the
# node's era-forecast horizon, which is only guaranteed to reach one SAFE ZONE
# ahead — half an epoch here (`eraSafeZone = StandardSafeZone 90` for 180-slot
# epochs). So the epoch must exceed twice the longest validity window in play,
# which is BitcoinValidator.MaxValidityWindow, 10 minutes, on every oracle
# transaction. Get it wrong and the failure is TimeTranslationPastHorizon: a wall
# of ouroboros-consensus call stack naming a future slot, which reads like a clock
# problem and is not one.
#
# From above: the companion-mode bootstrap has Yano produce the whole chain and
# the Haskell node then REPLAY it block by block. At 10800 the replay never
# finished and block production simply stopped — a devnet that answers queries and
# confirms nothing.
#
# 1200 satisfies both. `pegin-request`'s own TTL is a config value rather than a
# constant precisely so it can fit under this (see binocular
# bridge.pegin-request-ttl-seconds). Nothing here needs SHORT epochs: this
# scenario never waits for stake to activate.
#
# Assigned unconditionally, and from a scenario-specific variable: 00-lib.sh has
# already defaulted DEVNET_EPOCH_SLOTS by the time this line runs, so a
# `${DEVNET_EPOCH_SLOTS:-1200}` here would silently keep its 180.
DEVNET_EPOCH_SLOTS=${SCENARIO5_EPOCH_SLOTS:-1200}

CFG=(--config /etc/heimdall/heimdall.toml)
# x-only pubkey of bitcoin.y_fed_seed_hex (heimdall's default fe×32). Config #11
# on this deployment, and the key in the recovery leaf of BOTH taproot trees.
Y_FED_XONLY=0ce472ae5d8993e7609ee4ef33b344f6b8499a1259374bdf528f82240985bf03
# params[7] / params[8]. The refund window must open AFTER the federation's, and
# deploy-bridge refuses the pair if it does not.
FEDERATION_CSV_BLOCKS=${FEDERATION_CSV_BLOCKS:-144}
PEGIN_REFUND_TIMEOUT_BLOCKS=${PEGIN_REFUND_TIMEOUT_BLOCKS:-720}
# Treasury and deposit sizes. Both are counted by the final assertions.
TREASURY_FUND_SAT=${TREASURY_FUND_SAT:-100000000} # 1 BTC
DEPOSIT_SAT=${DEPOSIT_SAT:-250000}
DEPOSIT_FEE_SAT=${DEPOSIT_FEE_SAT:-1000}

log "step 0: infra up (bitcoind + yaci devnet)"
log "  building images from $HEIMDALL_SRC / $BINOCULAR_SRC (cached when unchanged)"
docker compose build heimdall-sweeper bitfrost
docker compose up -d bitcoind yaci-devkit
for _ in $(seq 60); do
  [ "$(docker compose ps --format '{{.Health}}' bitcoind)" = "healthy" ] && break
  sleep 2
done
btc_mine 101 # mature a coinbase for funding
curl -sf "$STORE_API/blocks/latest" >/dev/null 2>&1 || yaci_create_node
wait_store_api

# Render before any `docker compose run heimdall-sweeper`: the service mounts
# data/generated/heimdall-sweeper.toml and a missing bind source becomes a
# root-owned DIRECTORY. The early render keeps the @...@ placeholders — step 2
# reads only the [bitcoin] and [demo] sections, which are final from the start.
render_sweeper() {
  sed -e "s|@FEDERATION_CSV_BLOCKS@|$FEDERATION_CSV_BLOCKS|" \
    -e "s|@PEGIN_REFUND_TIMEOUT_BLOCKS@|$PEGIN_REFUND_TIMEOUT_BLOCKS|" \
    -e "s|@FEDERATION_ONE_SHOT@|${FEDERATION_ONE_SHOT:-@FEDERATION_ONE_SHOT@}|" \
    -e "s|@CONFIG_ADDRESS@|${CONFIG_ADDRESS:-@CONFIG_ADDRESS@}|" \
    -e "s|@CONFIG_NFT_POLICY@|${CONFIG_NFT_POLICY:-@CONFIG_NFT_POLICY@}|" \
    -e "s|@CONFIG_NFT_ASSET@|${CONFIG_NFT_ASSET:-@CONFIG_NFT_ASSET@}|" \
    -e "s|@TM_ADDRESS@|${TM_ADDRESS:-@TM_ADDRESS@}|" \
    -e "s|@TM_POLICY@|${TM_POLICY:-@TM_POLICY@}|" \
    -e "s|@TM_SCRIPT_CBOR@|${TM_SCRIPT_CBOR:-@TM_SCRIPT_CBOR@}|" \
    -e "s|@BRIDGE_STATE_POLICY@|${BRIDGE_STATE_POLICY:-@BRIDGE_STATE_POLICY@}|" \
    -e "s|@PEGIN_ADDRESS@|${PEGIN_ADDRESS:-@PEGIN_ADDRESS@}|" \
    -e "s|@PEGIN_POLICY@|${PEGIN_POLICY:-@PEGIN_POLICY@}|" \
    -e "s|@PEGOUT_ADDRESS@|${PEGOUT_ADDRESS:-@PEGOUT_ADDRESS@}|" \
    -e "s|@BRIDGED_TOKEN_UNIT@|${BRIDGED_TOKEN_UNIT:-@BRIDGED_TOKEN_UNIT@}|" \
    config/heimdall-sweeper.toml >data/generated/heimdall-sweeper.toml
}
mkdir -p data/generated data/sweeper keys
render_sweeper
# The depositor's Bitcoin key and the node's bifrost identity. Devnet-only.
[ -f keys/sweeper-bifrost.skey ] ||
  (umask 177 && printf '%s' "$(printf '55%.0s' $(seq 32))" >keys/sweeper-bifrost.skey)

log "step 1: fund both Cardano wallets from the devnet faucet"
# TWO wallets: binocular deploys and mints (WALLET_MNEMONIC), heimdall posts the
# TM (HEIMDALL_MNEMONIC). Genesis alone needs THREE clean pure-ADA UTxOs of the
# binocular wallet — one one-shot for config/cpi/bridge-state, a SECOND for the
# federation roots (the five scripts do not fit one 16 kB tx), and at least one
# more to pay fees from.
wallet_log="$LOGS/sweeper-wallet-address.log"
hs wallet-address "${CFG[@]}" 2>&1 | tee "$wallet_log" >/dev/null
HD_ADDR=$(extract "$wallet_log" 'addr_test1[a-z0-9]+')
bn_addr_log="$LOGS/binocular-wallet-address.log"
bn info 2>&1 | tee "$bn_addr_log" >/dev/null || true
BN_ADDR=$(extract "$bn_addr_log" 'addr_test1[a-z0-9]+')
log "  binocular wallet $BN_ADDR"
log "  heimdall wallet  $HD_ADDR"
# 1000 tADA a piece: the devkit's 20 accounts hold 10,000 each and are never
# refilled, so an over-generous run drains the devnet in a handful of iterations
# — which then fails at step 1 rather than anywhere informative. The largest
# single need is a reference-script UTxO, tens of ADA.
for _ in 1 2 3 4 5 6; do yaci_topup "$BN_ADDR" 1000; done
for _ in 1 2; do yaci_topup "$HD_ADDR" 1000; done
wait_utxo_count "$BN_ADDR" 6
wait_utxo_count "$HD_ADDR" 2

log "step 2: derive the treasury address (Y_51 + y_federation), OFF chain"
# The genesis anchor has to exist on Bitcoin before deploy-bridge writes it into
# the singleton, so this address cannot be read back from the Config — it is
# computed from the two keys and the CSV that the deploy is ABOUT to publish.
# `bootstrap-treasury` prints the other tree (Y_51 = y_federation), which is the
# genesis address of a bridge whose roster does not exist yet; this deployment
# starts with the demo roster already in place, so it anchors at the real one.
ft_log="$LOGS/frost-treasury.log"
hs frost-treasury "${CFG[@]}" \
  --y-federation "$Y_FED_XONLY" \
  --federation-csv-blocks "$FEDERATION_CSV_BLOCKS" 2>&1 | tee "$ft_log" >/dev/null
Y51=$(extract "$ft_log" 'FROST group key \(x-only\): [0-9a-f]{64}' | grep -oE '[0-9a-f]{64}')
TREASURY_ADDR=$(extract "$ft_log" 'Treasury address: bcrt1p[a-z0-9]+' | grep -oE 'bcrt1p[a-z0-9]+')
log "  Y_51 = $Y51"
log "  treasury = $TREASURY_ADDR"

log "step 3: fund the treasury on regtest ($TREASURY_FUND_SAT sat)"
btc loadwallet bench >/dev/null 2>&1 || btc createwallet bench >/dev/null 2>&1 || true
TREASURY_TX=$(btc -rpcwallet=bench sendtoaddress "$TREASURY_ADDR" \
  "$(python3 -c "print('%.8f' % ($TREASURY_FUND_SAT/1e8))")")
btc_mine 1
TREASURY_VOUT=$(btc getrawtransaction "$TREASURY_TX" true | python3 -c "
import json,sys
tx=json.load(sys.stdin)
print(next(o['n'] for o in tx['vout'] if o['scriptPubKey'].get('address')=='$TREASURY_ADDR'))")
log "  genesis anchor: $TREASURY_TX:$TREASURY_VOUT"

log "step 4: initialize the Bitcoin oracle on regtest"
# Start a few blocks BELOW the tip so the seeded confirmed range is already
# buried: the oracle's confirmed root is what `pegin-request` proves inclusion
# against, and a root anchored at the very tip has nothing mature under it.
BTC_TIP=$(btc getblockcount)
ORACLE_START_HEIGHT=$((BTC_TIP - 10))
# Exported BEFORE init and kept for every later command: it is the lower bound of
# the confirmed-blocks MPF, and each rebuild of that MPF walks from it.
bn_env ORACLE_START_HEIGHT "$ORACLE_START_HEIGHT"
init_log="$LOGS/oracle-init.log"
bn init --start-block "$ORACLE_START_HEIGHT" --confirmed-until $((BTC_TIP - 5)) 2>&1 |
  tee "$init_log" >/dev/null
# Normalized to TXHASH#INDEX whatever `init` printed: older builds rendered
# scalus's TransactionInput toString here, and the difference only surfaces one
# command later as "Invalid TxOutRef format".
ORACLE_ONE_SHOT=$(bn_field "$init_log" 'One-shot' |
  sed -E 's/.*"?([0-9a-f]{64})"?[^0-9]*([0-9]+).*/\1#\2/')
ORACLE_OWNER_PKH=$(bn_field "$init_log" 'Owner PKH')
bn_env ORACLE_TX_OUT_REF "$ORACLE_ONE_SHOT"
bn_env ORACLE_OWNER_PKH "$ORACLE_OWNER_PKH"
log "  oracle one-shot $ORACLE_ONE_SHOT owner $ORACLE_OWNER_PKH"

log "step 5: deploy the bridge (WI-068 genesis: federation roots, then the Config)"
bn_env INITIAL_BTC_TREASURY_UTXO "$TREASURY_TX:$TREASURY_VOUT"
bn_env INITIAL_BTC_TREASURY_AMOUNT_SAT "$TREASURY_FUND_SAT"
bn_env BIFROST_Y_FEDERATION_HEX "$Y_FED_XONLY"
bn_env BIFROST_FEDERATION_CSV_BLOCKS "$FEDERATION_CSV_BLOCKS"
bn_env BIFROST_PEGIN_REFUND_TIMEOUT_BLOCKS "$PEGIN_REFUND_TIMEOUT_BLOCKS"
# Well under the ~600 s the 1200-slot epoch guarantees ahead (see DEVNET_EPOCH_SLOTS).
bn_env BIFROST_PEGIN_REQUEST_TTL_SECONDS 300
bn_env BIFROST_BASE_BAN_DURATION_MS "$BAN_BASE_DURATION_MS"
bn_env BIFROST_MAX_FAULTS_BEFORE_PERMANENT "$BAN_MAX_FAULTS_BEFORE_PERMANENT"
bn_env BIFROST_MAX_VALIDITY_WINDOW_MS "$BAN_MAX_VALIDITY_WINDOW_MS"
deploy_log="$LOGS/deploy-bridge.log"
bn deploy-bridge 2>&1 | tee "$deploy_log" >/dev/null
CONFIG_NFT_POLICY=$(bn_field "$deploy_log" 'config-nft-policy-id')
CONFIG_NFT_ASSET=$(bn_field "$deploy_log" 'config-nft-asset-name')
CONFIG_ADDRESS=$(bn_field "$deploy_log" 'config address')
BRIDGED_TOKEN_POLICY=$(bn_field "$deploy_log" 'bridged-token-policy-id')
BRIDGED_TOKEN_ASSET=$(bn_field "$deploy_log" 'bridged-token-asset-name')
BRIDGED_TOKEN_UNIT="$BRIDGED_TOKEN_POLICY$BRIDGED_TOKEN_ASSET"
BRIDGE_STATE_POLICY=$(bn_field "$deploy_log" 'bridge-state-policy-id')
CPI_ONE_SHOT=$(bn_field "$deploy_log" 'completed-peg-ins-one-shot-ref')
BSS_ONE_SHOT=$(bn_field "$deploy_log" 'bridge-state-one-shot-ref')
FEDERATION_ONE_SHOT_HASH=$(bn_field "$deploy_log" 'federation-one-shot-ref')
FEDERATION_ONE_SHOT=$(bn_field "$deploy_log" 'heimdall registry_bootstrap / treasury_bootstrap')
PEGIN_POLICY=$(bn_field "$deploy_log" 'peg_in withdraw hash')
PEGIN_ADDRESS=$(bn_field "$deploy_log" 'heimdall pegin_script_address')
PEGOUT_ADDRESS=$(bn_field "$deploy_log" 'heimdall pegout_script_address')
log "  config NFT $CONFIG_NFT_POLICY.$CONFIG_NFT_ASSET at $CONFIG_ADDRESS"
log "  federation one-shot $FEDERATION_ONE_SHOT_HASH"
bn_env CONFIG_NFT_POLICY_ID "$CONFIG_NFT_POLICY"
bn_env BRIDGED_TOKEN_POLICY_ID "$BRIDGED_TOKEN_POLICY"
bn_env COMPLETED_PEG_INS_ONE_SHOT_REF "$CPI_ONE_SHOT"
bn_env BRIDGE_STATE_ONE_SHOT_REF "$BSS_ONE_SHOT"
bn_env FEDERATION_ONE_SHOT_REF "$FEDERATION_ONE_SHOT_HASH"

log "step 6: the TM validator (parameterized by the oracle + this Config NFT)"
tm_log="$LOGS/tm-script.log"
bn tm-script 2>&1 | tee "$tm_log" >/dev/null
TM_POLICY=$(bn_field "$tm_log" 'policy_id')
TM_ADDRESS=$(bn_field "$tm_log" 'address')
TM_SCRIPT_CBOR=$(bn_field "$tm_log" 'cbor')
log "  TM validator $TM_POLICY at $TM_ADDRESS"

log "step 7: publish the CIP-33 reference scripts"
refs_log="$LOGS/deploy-script-refs.log"
bn deploy-script-refs 2>&1 | tee "$refs_log" >/dev/null

log "step 8: render the heimdall config against the deployed bridge"
render_sweeper
log "  peg-in $PEGIN_ADDRESS"
log "  peg-out $PEGOUT_ADDRESS"

log "step 9: heimdall agrees with the chain about the treasury"
st_log="$LOGS/show-treasury.log"
hs show-treasury "${CFG[@]}" 2>&1 | tee "$st_log" >/dev/null
grep -q "our Y_51:             $Y51" "$st_log" ||
  die "show-treasury derived a different Y_51 than step 2 — see $st_log"
grep -qE "CURRENT TREASURY \(singleton head\): $TREASURY_TX:$TREASURY_VOUT" "$st_log" ||
  die "the singleton head is not the anchor funded in step 3 — see $st_log"
log "  singleton head = $TREASURY_TX:$TREASURY_VOUT, Y_51 agrees"

log "step 10: build the depositor's 35-byte-beacon deposit"
# The depositor is the one actor that cannot read the Config, so every input to
# the deposit ADDRESS is passed explicitly. A wrong one here produces a
# well-formed P2TR that no sweep can ever find (WI-074).
# The key is generated HERE, not by bitcoind: `dumpprivkey` works only on legacy
# wallets, and Bitcoin Core has created descriptor wallets by default since v23
# (it answers "Only legacy wallets are supported by this command"). A fixed
# devnet-only secret keeps the deposit address stable across runs, which makes a
# failed sweep re-inspectable.
# -s, not -f: a redirect that fails still leaves a zero-byte file behind, and the
# next run would then skip generation and hand bitcoind an empty key.
[ -s keys/depositor.wif ] || {
  python3 - <<'PY' >keys/depositor.wif
import hashlib
# WIF, compressed, testnet/regtest prefix 0xEF. Devnet-only secret, 0x77 x32.
payload = b"\xef" + b"\x77" * 32 + b"\x01"
raw = payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = int.from_bytes(raw, "big")
out = ""
while n:
    n, r = divmod(n, 58)
    out = alphabet[r] + out
print("1" * (len(raw) - len(raw.lstrip(b"\x00"))) + out, end="")
PY
  chmod 600 keys/depositor.wif
}
# Its P2WPKH address, from the node rather than re-implemented here — a mismatch
# between the address funded and the one the depositor spends from would surface
# as "no UTXOs" with no hint that the derivation was the problem.
DEP_DESC=$(btc getdescriptorinfo "wpkh($(cat keys/depositor.wif))" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["descriptor"])')
DEP_ADDR=$(btc deriveaddresses "$DEP_DESC" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
log "  depositor $DEP_ADDR"
btc -rpcwallet=bench sendtoaddress "$DEP_ADDR" \
  "$(python3 -c "print('%.8f' % (($DEPOSIT_SAT + $DEPOSIT_FEE_SAT + 50000)/1e8))")" >/dev/null
btc_mine 1
dep_log="$LOGS/depositor.log"
hs_depositor "${CFG[@]}" \
  --frost-key "$Y51" \
  --y-federation "$Y_FED_XONLY" \
  --federation-csv-blocks "$FEDERATION_CSV_BLOCKS" \
  --refund-timeout-blocks "$PEGIN_REFUND_TIMEOUT_BLOCKS" \
  --depositor-wif-file /keys/depositor.wif \
  --deposit-amount-sat "$DEPOSIT_SAT" --fee-sat "$DEPOSIT_FEE_SAT" \
  --submit 2>&1 | tee "$dep_log" >/dev/null
# `txid = …` from the broadcast, or `txid: …` from the depositor's own line — the
# latter is logged below the depositor target's level, so it is not always there.
DEPOSIT_TX=$(extract "$dep_log" 'txid[ :=]+[0-9a-f]{64}' | grep -oE '[0-9a-f]{64}')
btc_mine 1
# The beacon is output 1: OP_RETURN PUSH35 "BFR" || Q_auth. Assert its WIDTH here,
# where a 67-byte two-key beacon would still be well-formed Bitcoin — the on-chain
# validator refuses it, but only after everything else has already happened.
BEACON_SPK=$(btc getrawtransaction "$DEPOSIT_TX" true |
  python3 -c 'import json,sys
tx=json.load(sys.stdin)
print(next(o["scriptPubKey"]["hex"] for o in tx["vout"] if o["scriptPubKey"]["type"]=="nulldata"))')
[ "${#BEACON_SPK}" = 74 ] ||
  die "beacon scriptPubKey is $((${#BEACON_SPK} / 2)) bytes, want 37 (6a 23 'BFR' || Q_auth): $BEACON_SPK"
case "$BEACON_SPK" in 6a23424652*) ;; *) die "beacon does not start 6a 23 'BFR': $BEACON_SPK" ;; esac
Q_AUTH=${BEACON_SPK: -64}
log "  deposit $DEPOSIT_TX, beacon Q_auth = $Q_AUTH"

log "step 11: mature the deposit into the oracle's confirmed root"
# `pegin-request` proves the deposit's block is in the oracle's confirmed MPF, so
# the block must be maturation-confirmations deep AND have aged challenge-aging
# inside the oracle. Regtest blocks are free; the aging is wall clock.
btc_mine 5

log "step 12: mint the PegInRequest on Cardano"
# The oracle is driven SYNCHRONOUSLY with `update-oracle` rather than by leaving
# the `run` daemon in the background: a daemon that dies takes its diagnosis with
# it (the container is gone by the time the scenario fails), and its progress is
# invisible from here. Each pass advances the oracle to the current regtest tip,
# then retries the mint. The gate is real — the deposit's block must be
# maturation-confirmations deep AND have aged challenge-aging inside the oracle,
# the latter in wall-clock seconds — so this loop legitimately takes minutes.
pir_log="$LOGS/pegin-request.log"
upd_log="$LOGS/update-oracle.log"
for attempt in $(seq 30); do
  bn update-oracle --to "$(btc getblockcount)" 2>&1 | tee "$upd_log" >/dev/null || true
  if bn pegin-request "$DEPOSIT_TX" 2>&1 | tee "$pir_log" >/dev/null; then
    break
  fi
  # The two shapes the gate takes: the block is not in the confirmed MPF at all
  # ("Key not in trie"), or the proof builder names it outright. Anything else is
  # a real failure and must not be retried for ten minutes.
  grep -qE "Key not in trie|BlockNotConfirmedByOracle" "$pir_log" ||
    die "pegin-request failed for a reason other than the maturation gate — see $pir_log"
  log "  deposit not yet in the oracle's confirmed root (attempt $attempt); mining + waiting"
  btc_mine 1
  sleep 20
done
grep -qE "Key not in trie|BlockNotConfirmedByOracle" "$pir_log" &&
  die "the deposit never entered the oracle's confirmed root — see $pir_log and the bitfrost logs"
log "  PegInRequest minted"

log "step 13: sweep — the TM spends the deposit"
# `sweep-pegins`, not `run-mover`: identical code path (the mover wraps it), but
# unconditional. The mover only builds at a batch opportunity on the Config's
# slot grid, so a --once tick is a no-op most of the time — a scheduling property
# worth its own scenario, and noise in this one.
sweep_log="$LOGS/sweep-pegins.log"
hs sweep-pegins "${CFG[@]}" \
  --cardano-socket /dev/null --cardano-magic 42 \
  --broadcast 2>&1 | tee "$sweep_log" >/dev/null
TM_BTC_TX=$(sed -n '/Treasury Movement (sweep peg-ins)/,$p' "$sweep_log" |
  grep -oE '[0-9a-f]{64}' | head -1)
[ -n "$TM_BTC_TX" ] || die "no TM txid in $sweep_log"
btc_mine 1
log "  TM btc tx $TM_BTC_TX"

log "step 14: assert — the deposit is SPENT on Bitcoin, by that TM"
spent=$(btc gettxout "$DEPOSIT_TX" 0 2>/dev/null || true)
[ -z "$spent" ] || die "the deposit output is still unspent — the sweep did not land"
btc getrawtransaction "$TM_BTC_TX" true >"$LOGS/tm-btc-tx.json" 2>/dev/null ||
  die "TM $TM_BTC_TX is not on regtest"
python3 - "$LOGS/tm-btc-tx.json" "$DEPOSIT_TX" "$TREASURY_TX" "$TREASURY_VOUT" <<'PY' || die "TM does not spend the deposit"
import json, sys
tx = json.load(open(sys.argv[1]))
deposit, treasury_tx, treasury_vout = sys.argv[2], sys.argv[3], int(sys.argv[4])
ins = {(i["txid"], i["vout"]) for i in tx["vin"]}
assert (deposit, 0) in ins, f"deposit {deposit}:0 not among the TM inputs {ins}"
assert (treasury_tx, treasury_vout) in ins, f"treasury not among the TM inputs {ins}"
# A key-path spend: one 64/65-byte Schnorr signature and nothing else. The tweak
# it verifies under is the merkle root of the tree built from the beacon's Q_auth,
# so a wrong refund-leaf key fails HERE, inside bitcoind's script check.
for i in tx["vin"]:
    if (i["txid"], i["vout"]) == (deposit, 0):
        w = i["txinwitness"]
        assert len(w) == 1 and len(w[0]) in (128, 130), f"deposit spend is not a key-path spend: {w}"
print(f"OK: TM {tx['txid']} spends the deposit key-path and the treasury")
PY
log "OK: the 35-byte beacon deposit $DEPOSIT_TX:0 was swept by TM $TM_BTC_TX"
log "    Q_auth $Q_AUTH reached the refund leaf — the taproot tweak verified on Bitcoin"
