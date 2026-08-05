# TM Confirmed-Chain Migration Runbook (preprod)

Migrates the deployed preprod bridge to the confirmed-chain treasury tracking scheme
AND the attested-root peg-out termination scheme (spec:
`docs/superpowers/specs/2026-07-20-tm-confirmed-chain-design.md`,
`docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`, rev 5.1)
**without redeploying the bridge**: the config NFT, fSAT policy, completed-peg-ins tree
and the Binocular oracle keep their hashes and UTxOs. The TM validator, the peg-in
script (via its TM-NFT-policy parameter), and the peg-out script all get new hashes;
the completed-peg-outs trie gets a fresh singleton (a NEW policy id, not a re-mint of
the old one); and one config `Update` transaction rewires the deployed Config UTxO.

Operator prerequisites: the binocular sponsor wallet (funds + the `oracle.owner-pkh`
`update_auth` key), bitcoind (testnet4) RPC, Blockfrost preprod access.

## 1. Export the new TM validator

```bash
binocular tm-script
```

Note the printed `policy_id` (= new TM NFT policy = new TM script hash) and `address`
(the new TM address), and save the `cbor` for heimdall. The script is parameterized by
`(oracle script hash, config NFT policy, config NFT asset name)` from the binocular
bridge config, so `bridge.config-nft-{policy-id,asset-name}` must already be set.

## 2. Compute the new peg-in and peg-out hashes, and register their reward accounts

The TM NFT policy is `peg-in.ak`'s 4th parameter, so the peg-in script hash changes.
`peg-out.ak` changes too, independent of any parameter — its Complete/Cancel logic was
rewritten for the attested-root scheme (permissionless completion; membership /
non-membership proofs against the completed-peg-outs trie instead of the withdrawn
Binocular-verifier scheme). `binocular deploy-bridge --dry-run` prints the full derived
hash chain, including `peg_in withdraw hash` and `peg_out withdraw hash`, without
submitting.

Register both new withdraw reward accounts (deposit-less RegCert) before completions
run:

```bash
binocular register-bridge-creds
```

This command is idempotent — safe to re-run after the config swap in step 6.
**Vestigial**: the old `legit_treasury_movement_and_peg_out_produced` verifier's reward
account (Config field 7) needed its own registration in pre-rev-5.1 deployments; under
rev 5.1 that verifier is never invoked, so it needs no registration on this migration
(see *Register script reward accounts* in the technical documentation).

## 3. Bootstrap the completed-peg-outs trie

```bash
binocular bootstrap-completed-peg-outs --one-shot-ref <TX_HASH>#<INDEX>
```

Mints a **fresh** completed-peg-outs singleton (zero root), parameterized by the NEW TM
NFT policy from step 1 — so its spend is gated on the Unconfirmed→Confirmed transition
of the NEW TM script only, never the old one. This is a new policy id, not a re-mint at
the old completed-peg-outs address: the old instance and every old (unpaid) PegOut
request are abandoned in place (see step 5). Omit `--one-shot-ref` to auto-pick the
largest clean pure-ADA UTxO in the sponsor wallet. Note the printed policy id — it
becomes Config field 3 in step 6.

## 4. Complete in-flight peg-ins under the OLD TM policy

Peg-ins already swept by old-policy Confirmed TM records must be completed BEFORE the
config swap in step 6: the new peg-in script only recognizes the new TM NFT policy, and
after field 4 is swapped the old peg-in withdraw script no longer gates fSAT minting.

Peg-outs already **paid** by an old-policy TM (i.e. present in the OLD completed-peg-outs
trie) should likewise be completed before or shortly after the swap — completion is
permissionless, so anyone may still do this against the OLD trie and OLD peg-out script
after the swap, since neither is spent or altered by the migration. Peg-outs that were
never paid become **abandoned**: the new roster's TM builder only ever looks at the new
peg-out script's UTxOs, so an old, unpaid PegOut request can only be recovered by its
owner via *Cancel PegOut request* once its `created + 30 days` timeout elapses — the old
completed-peg-outs trie stays frozen at its pre-migration root, so the non-membership
proof stays valid for it forever.

## 5. Pick the treasury anchor

Determine the current unspent Bitcoin treasury outpoint on testnet4 (display txid +
vout). Verify it is unspent:

```bash
bitcoin-cli -testnet4 gettxout <TXID> <VOUT>
```

This becomes the chain's "initial" outpoint; the first post-migration TM must spend it.
Config field 11 is **optional** in step 6 — omit it to leave the deployed anchor
unchanged (only meaningful the first time this migration runs on a given instance;
re-running with a fresh anchor is the emergency federation-sweep re-anchoring path).

## 6. Update the deployed Config UTxO

**Ordering is load-bearing.** Steps 1–3 (new TM script exported, new peg-in/peg-out
hashes computed, the completed-peg-outs singleton minted) MUST all complete before this
step: the CPO singleton named by field 3 MUST already exist, and field 3 MUST name it,
before the first Confirm runs under the new TM script — `TreasuryMovementValidator`'s
Confirm branch reads field 3 to find the trie to spend and recreate (see *Confirm TM
tx*, checks [CTM-9]–[CTM-13]), so a Confirm attempted before this Update would find no
config-named trie to authenticate.

```bash
binocular update-config \
  --initial-btc-treasury-utxo <TXID>:<VOUT> \
  --peg-in-withdraw-hash <new peg-in hash from step 2> \
  --completed-peg-outs-policy <new CPO trie policy from step 3> \
  --peg-out-withdraw-hash <new peg-out hash from step 2>
```

One transaction, authorized by `update_auth` (the oracle owner key), swaps fields 3
(`completed_peg_outs_merkle_tree_policy_id`), 4 (`peg_in_withdraw_script_hash`), and 5
(`peg_out_withdraw_script_hash`) together. `--initial-btc-treasury-utxo` is optional
(step 5) — omit it to keep the deployed field 11 unchanged. Dry-run first with
`--dry-run`. The command is re-runnable and idempotent per field.

## 7. Reconfigure heimdall

In `heimdall.toml` `[cardano]`:

- `treasury_address` = the new TM address (step 1)
- `treasury_policy_id` = the new TM policy id (step 1), `treasury_asset_name` = `""`
- `tm_script_cbor` = the CBOR from step 1
- `config_address`, `config_nft_policy_id`, `config_nft_asset_name` = the deployed
  config values (from `binocular deploy-bridge` output / the config UTxO)

Deleted keys (remove if present): `[bitcoin] treasury_txid/treasury_vout/
treasury_amount_sat`, `[cardano] tm_control_ref`.

**Genesis treasury value (rev 5.1 infrastructure assumption).** SPOs do not run Bitcoin
nodes as part of steady-state operation — nothing in the peg-out termination flow needs
a Bitcoin-side query, and the completed-peg-outs root travels entirely through Cardano
data (the CPOR1 commitment and the `fulfilled_por_outpoints` datum hint). The genesis
treasury outpoint's satoshi VALUE is the one input this instance cannot derive from
Cardano state before any TM has confirmed against it, so it is **operator-supplied
configuration**, entered once at migration time, rather than fetched automatically via
`bitcoind gettxout` at every heimdall startup. An operator MAY still use
`bitcoin-cli gettxout` (as in step 5) as a one-time convenience to look the value up —
that is a migration-time bootstrap aid, not a steady-state dependency. From the first
post-migration Confirm onward, the chain tip's treasury output is the compliant
current-state source (see *Infrastructure assumptions* in the technical documentation).

## 8. Reconfigure binocular relay/confirm

`bridge.tm-control-nft-{policy,name}` and `bridge.tm-authorized-minter` no longer
exist. The relay/confirm/watchtower daemons derive the TM address from
`(oracle, config NFT)` automatically; no per-daemon TM settings beyond the bridge
config NFT values.

Set `bridge.completed-peg-outs-one-shot-ref` to the outpoint consumed in step 3 (or,
after the mint has landed, to any stable reference the confirm daemon needs to
reconstruct the trie contract — see the deployed `binocular` config docs).
`confirm-tmtx` hard-requires this key and refuses to start without it, since Confirm
now also spends and recreates the completed-peg-outs singleton every time (see step 6's
ordering note). Restart the watchtower/confirm daemon after setting it.

## 9. Verify end to end

1. Heimdall `query_treasury` resolves the anchor (log line
   `treasury = config anchor <txid>:<vout>`).
2. Heimdall builds, FROST-signs, broadcasts and posts the first TM
   (mint redeemer `Genesis`, config UTxO referenced), including its CPOR1 root
   commitment output (the unchanged zero root, if this TM fulfills no peg-out).
3. Binocular `confirm-tmtx` confirms it after Bitcoin confirmation; the record becomes
   the chain tip, and the completed-peg-outs singleton is spent and recreated carrying
   the attested root in the same transaction.
4. Heimdall's next `query_treasury` reports `treasury = TM chain tip <btc_txid>:0` and
   the next TM posts with redeemer `Chain(0)` referencing the tip record.
5. Once a TM fulfilling at least one peg-out confirms, verify a third party (not the
   PegOut's owner) can complete it — `binocular peg-out-complete` (or equivalent)
   against the new peg-out script, supplying only a membership proof — and that the
   completer, not the original owner, receives the MIN_ADA.

Old TM records and the TMCTRL UTxO are abandoned in place; they are not on the new
chain and are never read. The old completed-peg-outs singleton and any unpaid old
PegOut requests are likewise abandoned — see step 4.
