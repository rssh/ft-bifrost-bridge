# Peg-Out Fulfilled-Trie Design (OP_RETURN-committed POR ids)

Date: 2026-07-22
Status: Draft — pending review
Supersedes: the pinned-treasury-outpoint peg-out completion/cancel scheme
(technical_documentation.md §Create/Complete/Cancel PegOut request; the
`legit_TM_and_peg_out_produced` / `not_produced` verifier delegation in
`peg-out.ak`).

## Problem

The current peg-out termination design pins the TM-chain tip outpoint in each
PegOutRequest (POR) datum; Complete/Cancel prove that *the* Bitcoin tx spending
that pinned outpoint does / does not pay the destination, via two delegated
verifier scripts. Verified defects:

1. **Unimplemented and unimplementable as deployed.** Both verifier config
   fields (indexes 7, 8) hold dummy hashes and the placeholder validators were
   deleted (`7b7a7ee`). Complete and Cancel are unsatisfiable today.
2. **Stale-pin double-claim.** A POR pinning an already-spent treasury outpoint
   T_old can always cancel (T_old's spender predates it and pays nobody). If
   the SPO TM builder ever fulfills such a POR, the requester takes the BTC
   *and* reclaims the fBTC. Safety rests entirely on off-chain builder
   discipline.
3. **Duplicate `(dest, amount)` requests deadlock.** Two identical PORs pinning
   the same tip with one fulfilling output: the second can neither complete
   (paying outpoint already claimed in the completed trie) nor cancel (an
   output paying `(dest, amount)` exists). fBTC locked forever.
4. **Poor liveness.** A POR is only fulfillable by the single TM spending its
   pinned tip; every request that misses its TM window must cancel, re-create,
   and re-pin, repeatedly and under contention.

## Design

### Core idea

A new **fulfilled-peg-outs Merkle Patricia trie** (NFT-authenticated singleton,
like the completed-peg-ins trie) records every peg-out ever paid by a confirmed
TM, keyed by **POR id**. The TM Bitcoin transaction itself commits, in a
FROST-signed **OP_RETURN output**, which POR each peg-out output fulfills. The
TM Confirm transition inserts those entries; peg-out Complete proves membership
(with value binding), Cancel proves non-membership after a timeout. PORs no
longer pin a treasury outpoint — any future TM can fulfill any pending POR.

This inherits the TM confirmed-chain's trust model: the trie is updated only at
Confirm (oracle-proven Bitcoin reality), the mapping is committed inside the
FROST-signed Bitcoin bytes (SPO-attested, not forgeable by a permissionless
Cardano poster), and peg-out termination needs no SPV proofs at all — one MPF
proof against a reference input.

### Identifiers and encodings

- **POR id** (32 bytes): `utils.hash_output_ref` of the POR UTxO's own
  outpoint, i.e. `sha2_256(serialise_data(OutputReference))`. Computable
  on-chain at spend time from the POR input's `output_reference`; heimdall
  replicates the Plutus-Data CBOR encoding off-chain (same scheme as PIR NFT
  asset names).
- **Trie key**: the POR id. Globally unique (UTxO outpoints are unique), so
  inserts never collide across TMs, repeat peg-outs to the same destination
  work, and Cancel's exclusion proof is unambiguous.
- **Trie value**: `dest_scriptPubKey ++ amount_le8`, where `amount_le8` is the
  8-byte little-endian satoshi amount of the paying Bitcoin output (net of the
  pinned per-pegout fee). Raw concatenation — MPF hashes values internally.
- **OP_RETURN payload**: `"BFR1" ++ concat(por_id_0 .. por_id_{m-1})` — a
  4-byte ASCII tag then the 32-byte POR ids, in the exact order of the TM's
  peg-out outputs. Always present as the **last** output of every TM (payload =
  just the tag when a TM fulfills zero peg-outs). Size 4 + 32·m bytes is
  standard under current Core relay defaults.
- **TM output layout** becomes: `[0]` = treasury change, `[1..m]` = peg-out
  payments (sorted by scriptPubKey bytes, as today), `[m+1]` = OP_RETURN
  commitment. `outputs[i]` is fulfilled for `por_id_{i-1}`.

### On-chain: Scalus `TreasuryMovementValidator` (binocular)

`TmDatum` and `PegOutEntry` shapes are **unchanged** (no mirror churn in
peg-in.ak / heimdall parsers). The Confirm spend branch gains:

1. Locate the Config UTxO among reference inputs (by config NFT — parameters
   already applied) and read field 12, the fulfilled-trie NFT policy id.
2. Require the fulfilled-trie UTxO (its NFT, constant asset name) to be
   **spent** in this tx, with a continuing output carrying the NFT: same
   address, non-lovelace value preserved.
3. Parse the OP_RETURN commitment from the (already parsed) outputs: the last
   output's scriptPubKey must be `OP_RETURN` carrying the `"BFR1"` tag and
   exactly `m` POR ids, where outputs `1..m` are the peg-out payments
   (everything between treasury change and the OP_RETURN).
4. Fold the trie root: for each `(por_id_i, outputs[i+1])`, apply the redeemer-
   supplied MPF step — either `Insert(proof)` (normal) or
   `AlreadyPresent(proof)` (verify existing membership with the **same** value
   and leave the root unchanged — tolerance so an SPO double-fulfillment bug
   cannot permanently stall TM confirmation, which would strand swept
   peg-ins). Require the final root to equal the trie continuing output's
   datum root.

`TmConfirmRedeemer` gains the per-entry step list. GC / mint paths unchanged.
The TM script hash changes → the peg-in `tm_nft_policy_id` parameter value
changes (migration is still unexecuted; fold in).

No circular parameterization: the TM validator learns the trie policy from
config field 12 at runtime; the trie validator takes the TM policy id as a
compile parameter (TM hash is computable first — its parameters are unchanged).

### On-chain: Aiken

**New `fulfilled-peg-outs-merkle-tree.ak`** (modeled on
`completed-peg-outs-merkle-tree.ak`):

- `mint`: one-shot bootstrap — spends a designated input, mints the single NFT
  (constant asset name) into an output at its own script address with the
  empty MPF root datum `{root}`.
- `spend`: permitted iff the same tx performs a TM Confirm transition: an
  input carrying the TM NFT (policy = the `tm_nft_policy_id` parameter, empty
  asset name) whose inline datum is Constr **0** (Unconfirmed), and an output
  carrying that NFT with datum Constr **1** (Confirmed). Constructor-tag
  checks on raw Data only — no field decoding, so no arity coupling to the
  Scalus datum shape. Root/value/address correctness of the continuation is
  enforced by the Scalus confirm branch (mirror of how the completed trie
  delegates to `peg_out.ak`).

**`peg-out.ak` rewrite** (dramatic simplification — the oracle input, both
verifier delegations, and all SPV proof plumbing are deleted):

- `PegOutDatum` becomes
  `{owner_auth, dest_script_pub_key: ByteArray, per_pegout_fee: Int, created: Int}`
  — `source_chain_treasury_utxo_id` dropped (nothing to pin), `per_pegout_fee`
  pinned at lock time per the fee-immutability plan (deployment default 0),
  `created` in POSIX ms.
- New constant `peg_out_cancel_timeout_ms = 30 * 24 * 3600 * 1000` (30 days).
- `withdraw` redeemer: `{config_ref_input_index, fulfilled_trie_ref_input_index,
  action}` with `action = CompletePegOut{membership_proof} |
  Cancel{exclusion_proof}`.
- Shared: read config (field 12 → trie NFT policy); the fulfilled trie is a
  **reference input** (found at the given index, authenticated by its NFT) —
  Complete/Cancel never spend the singleton, removing that contention;
  `por_id = utils.hash_output_ref(peg_out_input.output_reference)`;
  `owner_auth` authorization as today.
- `CompletePegOut`: `mpf.has(trie_root, por_id,
  dest_script_pub_key ++ int_to_le8(fbtc_amount - per_pegout_fee), proof)`;
  all locked fBTC burnt (exact negative mint), as today. The completed-
  peg-outs trie is **no longer touched** (see Decisions).
- `Cancel`: tx validity interval entirely after `created +
  peg_out_cancel_timeout_ms`; `mpf.miss(trie_root, por_id, proof)`;
  `no_bridged_token_mint` (quantity 0) retained — it keeps bridged-token's
  presence-only burn delegation sound.
- `spend` handler: unchanged own-withdraw delegation.
- A stale-trie Cancel race is structurally impossible on-chain: referencing the
  trie UTxO pins its current state (a spent trie outpoint cannot be
  referenced), and the deeper signed-but-unconfirmed-TM race is closed by the
  SPO freshness margin (below).

**`config.ak` / `types/config.ak`**: append field 12
`fulfilled_peg_outs_merkle_tree_policy_id: PolicyId` + positional getter +
pin-test extension. Fields 7/8 (the two TM verifiers) become permanently
vestigial (documented; positions frozen).

**Unchanged**: `peg-in.ak` sources (only its applied `tm_nft_policy_id`
parameter value moves), `bridged-token.ak` (presence-only delegation to the
peg-out withdraw script — the peg_out hash it reads comes from config field 5,
swapped by the migration), `completed-peg-outs-merkle-tree.ak` (stays deployed,
now unused by the flow).

### Off-chain: heimdall

- `tm_builder.rs`: `PegOutRequest` gains `por_id: [u8; 32]` (and the pinned
  fee moves per-request); after sorting peg-outs by scriptPubKey, append the
  OP_RETURN output with the tag and the ids in output order. vsize estimate
  updated. Skipped peg-outs (dust / non-standard) are simply absent from the
  commitment — they cancel after the timeout.
- **Fulfillment freshness filter** (safety-critical, replaces pin discipline):
  only fulfill a POR when `created <= now` and
  `created + cancel_timeout - now >= safety_margin` (default margin 7 days,
  configurable). This single rule makes backdated `created` values harmless
  (a backdated POR is never fulfilled, so cancelling it only refunds the
  requester's own fBTC) and bounds the signed-but-not-yet-confirmed TM race.
- POR scanner: read PORs from the peg-out address with the new datum shape;
  compute POR ids (Plutus-Data CBOR + sha2_256); skip PORs whose id is
  already in the fulfilled trie (dedup against double-fulfillment, which the
  on-chain `AlreadyPresent` tolerance additionally defuses).
- `publish.rs` / confirm flow: the TM Confirm tx now also spends the
  fulfilled-trie UTxO and supplies the MPF step proofs (off-chain MPF
  maintained from the trie datum history / recomputed from Confirmed records).

### Off-chain: binocular

- `ConfirmTmtxCommand`: build the extended confirm tx — spend the trie UTxO,
  compute insert proofs, extended `TmConfirmRedeemer`.
- `DeployBridgeCommand` / `UpdateConfigCommand`: bootstrap the trie one-shot
  and the new config field (below).
- Validator tests: OP_RETURN parsing, insert fold, `AlreadyPresent` path,
  missing/wrong trie input, tag/count mismatches, zero-peg-out TMs.

### Migration (fold into the still-unexecuted preprod migration)

Extends `documentation/tm-chain-migration-runbook.md`; still one config Update
epoch, no bridge redeployment:

1. Build the new TM script (hash changes) → new peg-in hash (parameter) → new
   peg_out hash (rewrite) → trie validator hash (parameterized by the new TM
   hash).
2. One-shot mint the fulfilled-trie UTxO (empty root).
3. Config Update: append field 12 (trie policy id), swap field 4 (peg-in
   withdraw hash), swap field 5 (peg-out withdraw hash), field 11 anchor as
   already planned. Register the new peg-in and peg-out reward accounts.
4. Existing PORs at the old peg-out address (if any) predate the new scheme
   and are handled before the switch; the old completed-peg-outs trie is
   abandoned in place.

### Decisions (defaults adopted; flag to flip)

- **Trie key = POR id + OP_RETURN commitment** (user-selected). Fallback
  `(spk, amount)` keying rejected: insert collisions would permanently stall
  the TM chain and identical repeat peg-outs would be impossible.
- **POR identity/created = plain UTxO + SPO freshness filter** (no POR mint
  policy). The margin filter fully covers backdating; a PIR-style mint-gated
  POR NFT (anchoring `created` at the validity bound) remains the upgrade path
  if an on-chain guarantee is later wanted.
- **Completed-peg-outs trie retired from the flow.** POR ids are unique and a
  POR UTxO spends exactly once, so double-completion is impossible without it;
  dropping it removes the per-Complete singleton contention. The validator and
  config field 3 stay deployed, documented vestigial.
- **Cancel timeout = 30-day validator constant** (like `GcGraceMs`), not a
  config field. SPO margin 7 days. Tunable only by a peg_out script swap via
  config Update (field 5), which is acceptable given the config-swap machinery
  now exists.

### Residual risks (accepted)

- SPOs paying a peg-out on Bitcoin but the TM never confirming on Cardano
  within the cancel window would allow a double-claim; identical in kind to
  the TM-chain liveness assumption, bounded by the 23-day gap between margin
  and timeout (confirm latency is hours).
- An SPO quorum omitting a fulfilled POR's id from the OP_RETURN (or mapping
  it to a wrong id) burns treasury BTC without closing the POR — SPO fraud/bug
  territory, same trust class as treasury custody itself; the `AlreadyPresent`
  tolerance and heimdall dedup keep it from ever stalling the chain.

### Testing

- Scalus: confirm-path suites for the trie fold (happy, multi-peg-out,
  zero-peg-out, `AlreadyPresent`, wrong value, wrong count, missing tag,
  missing trie spend, forged trie NFT, wrong final root).
- Aiken: `peg-out.ak` Complete/Cancel suites (membership value binding, fee
  arithmetic, timeout boundary, exclusion proof, owner auth, burn exactness,
  no-mint-on-cancel); trie validator suites (bootstrap one-shot, spend gated
  on TM transition, constr-tag checks); config getter pin test for field 12.
- heimdall: builder OP_RETURN determinism, freshness filter boundaries, id
  hashing golden vectors against Aiken's `hash_output_ref`.
