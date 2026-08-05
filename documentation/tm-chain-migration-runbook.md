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

## 0. Plan the outage window

**Steps 3 through 8 are an outage for the confirm daemon and the watchtower.** Plan them
as one continuous maintenance window, not as separate chores across a week.

The window opens at step 3, when the fresh CPO singleton exists but Config field 3 still
names the old one. From that point until step 8 restarts the daemons with matching config:

- `confirm-tmtx` cannot confirm any TM. Confirm spends and recreates the CPO singleton
  named by Config field 3, so it fails from step 3 until step 6's Update lands, and keeps
  failing until step 8 restarts it against the new one-shot ref.
- The watchtower's POR sweeper completes nothing. It derives one peg-out script and one
  trie from the current config, so during the window it sees an inconsistent pair.
- Unconfirmed TMs accumulate on Cardano. They confirm normally once the window closes.
- The Bitcoin relay keeps running; nothing here touches the oracle.

Freeze new peg-in and peg-out requests for the duration, do not post new TMs during the
window, and hold the operator on call until step 9 verifies end to end. A window left
half-open (say, step 3 done and step 6 deferred) leaves the bridge unable to confirm
anything, which is the same as unable to mint or pay.

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
the old completed-peg-outs address: the old instance is abandoned in place, and any PegOut
request still at the old peg-out address is stranded (step 4b). Omit `--one-shot-ref` to
auto-pick the largest clean pure-ADA UTxO in the sponsor wallet. Note the printed policy
id — it becomes Config field 3 in step 6.

**Clear each SPO's local trie state.** The singleton this step mints holds the ZERO
root. Every heimdall node keeps a local mirror of the trie in
`<protocol.state_dir>/cpo-trie.json`, and it loads that file verbatim on startup. A file
left over from a previous bootstrap makes the node attest a root the fresh singleton does
not hold. On each SPO box, before restarting heimdall in step 7:

```bash
rm -f <protocol.state_dir>/cpo-trie.json
```

Re-running this migration on an instance that already has peg-out history is different:
do NOT delete the file blindly there. Rebuild it instead, so the mirror matches the live
singleton. Do this AFTER step 7, because the rebuild reads the new
`cardano.cpo_policy_id`:

```bash
heimdall reconstruct-cpo-trie --config heimdall.toml
```

Heimdall cross-checks its loaded root against the on-chain CPO singleton before it
attests, and refuses to sign on a mismatch, so a missed cleanup is loud rather than
silent. Do the cleanup anyway: the refusal stops TM production until an operator acts.

## 4. Drain the old scripts before the swap

### 4a. Complete in-flight peg-ins under the OLD TM policy

Peg-ins already swept by old-policy Confirmed TM records must be completed BEFORE the
config swap in step 6: the new peg-in script only recognizes the new TM NFT policy, and
after field 4 is swapped the old peg-in withdraw script no longer gates fSAT minting.

### 4b. Peg-outs under the old script are STRANDED. Verify there are none.

There is no migration path for a PegOut request that already sits at the OLD peg-out
script address. Paid or unpaid, it can be neither completed nor cancelled by any shipped
tooling. Read this before you touch anything.

**Why cancellation is impossible.** The deployed `peg-out.ak` `Cancel` branch delegates
to the `..._not_produced` verifier named by Config field 8, via
`stake_validator.validate_withdraw`. That verifier is
`fail("peg-out not-produced verifier: Cancel/refund path not implemented yet")` — a
script with no satisfying witness. Every Cancel transaction against the deployed peg-out
script therefore fails on-chain, whoever builds it and however long they wait. On top of
that, the deployed `PegOutDatum` has three fields (`owner_auth`,
`source_chain_destination_address`, `source_chain_treasury_utxo_id`) and no `created`
field, so no timeout can even be expressed. A previous revision of this runbook said the
owner could recover an unpaid request via *Cancel* after `created + 30 days`. **That was
wrong for the deployed script.** The 30-day Cancel is a rev-5.1 feature. It exists only
under the NEW peg-out script.

**Why completion is impossible.** The deployed `CompletePegOut` branch needs a withdrawal
from the Config field 7 verifier, plus a hand-built redeemer carrying the raw TM bytes, a
Bitcoin block header, an oracle inclusion proof, a transaction merkle proof, and an
exclusion proof against the OLD completed-peg-outs trie. Nothing in the tree builds that
transaction. The shipped `binocular peg-out-complete` cannot substitute: it derives BOTH
the peg-out script and the trie validator from the CURRENT blueprint
(`PegOutCompleteCommand.scala`), the rev-5.1 `CompletedPegOutsContract` takes 2 parameters
where the deployed v1 took 3, and `BridgeSweepSetup` requires Config field 3 to equal the
hash it derived. Pointing a throwaway config at the old hashes does not help: the command
builds the rev-5.1 membership-proof transaction, which the deployed script rejects.

**What to do.** Confirm the old peg-out address is empty BEFORE you start the switch.
Take the old peg-out script address from the deployed `binocular` config (the address
`binocular peg-out-request --dry-run` printed as `peg_out address` under the pre-migration
blueprint), then:

```bash
# Blockfrost: MUST print an empty array.
curl -s -H "project_id: $BLOCKFROST_PROJECT_ID" \
  "https://cardano-preprod.blockfrost.io/api/v0/addresses/<OLD_PEG_OUT_ADDRESS>/utxos"

# Kupo, if you run one: MUST print an empty array.
curl -s "$KUPO_URL/matches/<OLD_PEG_OUT_ADDRESS>?unspent"
```

- If the result is empty, proceed.
- If ANY UTxO is returned, STOP. Each one holds locked fBTC that the migration will
  strand permanently. Resolve them out-of-band before the switch: the fBTC supply and the
  Bitcoin treasury must be reconciled by hand, and any refund to the requester is a manual
  payment, not a protocol transaction. There is no command that does this for you. Do not
  proceed on the assumption that the owner can reclaim later.

The check is cheap and the failure is permanent, so run it even if you are certain no one
has used peg-out on this instance.

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
- `pegout_script_address` = the bech32 address of the NEW `peg_out.ak` script. **This key
  MUST change.** The peg-out script hash moves in this migration (step 2), so the address
  moves with it. Heimdall locates every pending peg-out through this address; leaving the
  old value in place stops peg-out payment silently — the TM builder simply finds nothing
  to pay and keeps posting peg-in-only movements. Get the value by running
  `binocular peg-out-request --dry-run` against the post-migration config and reading the
  printed `peg_out address`; its payment credential is the `peg_out withdraw hash` that
  `binocular deploy-bridge --dry-run` printed in step 2.
- `cpo_policy_id` = the completed-peg-outs trie policy id minted in step 3 (the same value
  that becomes Config field 3 in step 6). `reconstruct-cpo-trie` requires it: it is the
  only check that validates the rebuilt trie as a WHOLE, by comparing the reconstructed
  root against the on-chain CPO singleton. Without it the command fails at startup and
  writes nothing.

Deleted keys (remove if present): `[bitcoin] treasury_txid/treasury_vout/
treasury_amount_sat`, `[cardano] tm_control_ref`.

**Verify the two new keys took effect** after the restart, before you rely on the bridge:

```bash
# Lists the peg-outs heimdall can see at pegout_script_address. Builds and prints only;
# no --broadcast, so nothing is posted. A peg-out you created post-migration MUST appear.
heimdall run-mover --config heimdall.toml --once

# Reads cpo_policy_id, rebuilds the trie and cross-checks it against the on-chain CPO
# singleton. Prints "reconstructed root matches the on-chain CPO singleton".
heimdall reconstruct-cpo-trie --config heimdall.toml --dry-run
```

If `run-mover --once` reports no pending peg-outs while one exists on chain, the address
is wrong. If `reconstruct-cpo-trie` exits with a missing-`cpo_policy_id` error, the key
did not load.

**Genesis treasury value.** Before the first post-migration Confirm exists, nothing on
Cardano carries the anchor outpoint's satoshi VALUE: Config field 11 names the outpoint,
not its amount. Heimdall resolves it by calling `gettxout` on that outpoint, and it
hard-requires `[bitcoin] rpc_url` to do so. `query_treasury` fails with an error naming
that key if no Confirmed TM exists yet and no RPC endpoint is set. There is no
configuration key that supplies the value instead, so keep bitcoind RPC reachable from the
heimdall box until the first post-migration TM confirms. From that Confirm onward the
chain tip's treasury output is the current-state source and the Bitcoin dependency drops
out of steady state (see *Infrastructure assumptions* in the technical documentation, and
its *Implementation status* note).

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
ordering note). It is documented in binocular's `reference.conf` alongside the other
`bridge.*` keys. Restart the watchtower/confirm daemon after setting it.

This restart closes the outage window opened in step 0. Confirm it closed: the confirm
daemon must start without error and pick up the Unconfirmed TMs that accumulated during
the window.

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
5. Once a TM fulfilling at least one peg-out confirms, the watchtower's POR sweeper
   completes every paid request by itself: `confirm-tmtx` chains a Complete transaction
   after each Confirm (`bridge.por-sweeper`, on by default). Verify in the confirm log
   that `sweeper: completed <TX_HASH>#<INDEX>` appears and that the sweeper wallet — not
   the original owner — received the MIN_ADA. That is the third-party check: the
   watchtower never holds the PegOut owner's key.

   To drive it by hand instead (or to complete a request the sweeper skipped):

   ```bash
   binocular peg-out-complete --pegout <TX_HASH>#<INDEX>
   ```

   Omit `--pegout` to complete every completable request; add `--dry-run` to preview.
   The command reconstructs the completed-peg-outs trie from chain history, so it needs
   no local state and works from any machine with the bridge config.

Old TM records and the TMCTRL UTxO are abandoned in place; they are not on the new
chain and are never read. The old completed-peg-outs singleton is abandoned with them.
Any PegOut request still at the old peg-out address is STRANDED, not merely abandoned:
nothing can complete or cancel it. Step 4b is the check that keeps this from happening.
