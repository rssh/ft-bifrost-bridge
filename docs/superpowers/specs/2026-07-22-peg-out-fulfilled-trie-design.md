# Peg-Out Fulfilled-Trie Design (OP_RETURN-committed POR ids)

Date: 2026-07-22 (rev 2 — per-peg-out `"POR"` markers; aligned with N7/N10b datum
and the 17-field Config)
Status: Draft — pending review
Supersedes: the pinned-treasury-outpoint peg-out completion/cancel scheme
(technical_documentation.md §Complete peg-out [CPO-1..10], §Cancel PegOut
request [CXL-1..6], and the `legit_TM_and_peg_out_produced` / `not_produced`
verifier delegation in `peg-out.ak`).

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
   (paying outpoint already claimed in the completed trie, [CPO-7]) nor cancel
   (an output paying `(dest, amount)` exists, so [CXL-4] is unprovable). fBTC
   locked forever.
4. **Poor liveness.** A POR is only fulfillable by the single TM spending its
   pinned tip; every request that misses its TM window must cancel, re-create,
   and re-pin, repeatedly and under contention.

## Design

### Core idea

A new **fulfilled-peg-outs Merkle Patricia trie** (NFT-authenticated singleton,
like the completed-peg-ins trie) records every peg-out ever paid by a confirmed
TM, keyed by **POR id**. The TM Bitcoin transaction itself commits, in
FROST-signed **OP_RETURN marker outputs** (one per peg-out), which POR each
peg-out output fulfills. The TM Confirm transition inserts those entries;
peg-out Complete proves membership (with value binding), Cancel proves
non-membership after a timeout. PORs no longer pin a treasury outpoint — any
future TM can fulfill any pending POR.

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
- **POR marker output**: an OP_RETURN output with scriptPubKey
  `OP_RETURN OP_PUSHBYTES_35 ("POR" ++ por_id)` (37 script bytes, value 0),
  placed **immediately after** the peg-out payment output it labels. One
  marker per peg-out:
  - A single OP_RETURN listing all ids would breach the 80-byte
    datacarrier standardness payload limit at 3 or more peg-outs; per-output
    markers stay at 35 payload bytes regardless of batch size.
  - The prefix is `"POR"`, NOT a `"BFR"`-prefixed tag: watchtowers detect
    peg-in deposits by scanning for `"BFR"`-prefixed OP_RETURN outputs (the
    deposit beacon, tech doc §User peg-in flow), and a TM pays the treasury
    address in output 0 — a `"BFR*"` marker inside a TM could be misdetected
    as a deposit beacon.
- **TM output layout** becomes: `[0]` = treasury change, then one **pair** per
  fulfilled peg-out — `[2i+1]` = payment output `i` (pairs sorted by payment
  scriptPubKey bytes, as today), `[2i+2]` = its `"POR"` marker. Total outputs
  `1 + 2m`; a TM fulfilling zero peg-outs has only the change output.

### On-chain: Scalus `TreasuryMovementValidator` (binocular)

`TmDatum` and `PegOutEntry` shapes are **unchanged by this design** — they stay
the current (N7/N10b) shapes: `Unconfirmed(signedBtcTx, creator, created,
epoch, leaderReward)` and `Confirmed(btcTxid, sweptPegInUtxoIds,
fulfilledPegOuts, spentViaFederationLeaf, creator, created, epoch,
leaderReward)`. Marker outputs appear inside `fulfilledPegOuts` as inert
zero-amount entries, like the treasury change entry. No mirror churn in
`treasury-movement.ak` / heimdall parsers.

The Confirm spend branch gains, on top of its current checks (oracle proof,
datum reconstruction, federation-leaf flag):

1. Locate the Config UTxO among reference inputs (by config NFT — parameters
   already applied) and read field 3 — repurposed by the migration from the
   retired completed-peg-outs trie to the fulfilled-trie NFT policy id (see
   Decisions).
2. Require the fulfilled-trie UTxO (its NFT, constant asset name) to be
   **spent** in this tx, with a continuing output carrying the NFT: same
   address, non-lovelace value preserved.
3. Pair up the parsed outputs: after the change output, outputs come in
   (payment, marker) pairs — the marker's scriptPubKey must be
   `6a 23 "POR" ++ por_id` and the payment output must not itself be an
   OP_RETURN. An odd remainder or a malformed marker fails confirmation
   (such a TM must never be signed; see heimdall).
4. Fold the trie root: for each pair, apply the redeemer-supplied MPF step —
   either `Insert(proof)` (normal) or `AlreadyPresent(proof)` (verify existing
   membership with the **same** value and leave the root unchanged — tolerance
   so an SPO double-fulfillment bug cannot permanently stall TM confirmation,
   which would strand swept peg-ins). Require the final root to equal the trie
   continuing output's datum root.

`TmConfirmRedeemer` gains the per-pair step list. GC / mint paths unchanged.
The TM script hash changes → the peg-in `tm_nft_policy_id` parameter value
changes (migration is still unexecuted; fold in).

No circular parameterization: the TM validator learns the trie policy from
config field 3 at runtime; the trie validator takes the TM policy id as a
compile parameter (the TM hash is computable first — its own parameters are
unchanged).

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
  `{owner_auth, source_chain_destination_address, per_pegout_fee, created}` —
  `source_chain_treasury_utxo_id` dropped (nothing to pin; this also deletes
  the two "permanently unrecoverable" client-side footguns tied to it),
  `per_pegout_fee` pinned at lock time from Config #13 as already normative in
  the doc, `created` (POSIX ms) added for the cancel timeout.
- New constant `peg_out_cancel_timeout_ms = 30 * 24 * 3600 * 1000` (30 days).
- `withdraw` redeemer: `{config_ref_input_index, fulfilled_trie_ref_input_index,
  action}` with `action = CompletePegOut{membership_proof} |
  Cancel{exclusion_proof}`.
- Shared: read config (field 3 → trie NFT policy); the fulfilled trie is a
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

**`config.ak` / `types/config.ak`**: NO new field. Field 3 is renamed
`completed_peg_outs_merkle_tree_policy_id` →
`fulfilled_peg_outs_merkle_tree_policy_id` (position and type unchanged — the
frozen contract is positions + types; the rename is documentation) and its
getter follows. The migration Update swaps its VALUE to the new trie policy.
Fields 7/8 (the two TM verifiers) become permanently vestigial (documented;
positions frozen).

**Deleted**: `completed-peg-outs-merkle-tree.ak` and the `"CPO"` constant —
nothing needs the completion-side trie any more (see Decisions), and fresh
deploys stop bootstrapping it.

**Unchanged**: `peg-in.ak` sources (only its applied `tm_nft_policy_id`
parameter value moves), `bridged-token.ak` (presence-only delegation to the
peg-out withdraw script — the peg_out hash it reads comes from config field 5,
swapped by the migration), `treasury.ak` (FederationReset reads
`spent_via_federation_leaf` — orthogonal; if an emergency federation TM also
fulfills peg-outs, the same marker scheme applies with no special case).

### Off-chain: heimdall

- `tm_builder.rs`: `PegOutRequest` gains `por_id: [u8; 32]` and the
  datum-pinned fee; after sorting peg-outs by payment scriptPubKey, emit the
  (payment, marker) pair per peg-out. vsize estimate gains ~46 vB per marker.
  Skipped peg-outs (dust / non-standard) simply get no pair — they cancel
  after the timeout.
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
- Validator tests: marker parsing, pair walk, insert fold, `AlreadyPresent`
  path, missing/wrong trie input, malformed marker / odd output count /
  wrong-prefix tags, zero-peg-out TMs.

### Migration (fold into the still-unexecuted preprod migration)

Extends `documentation/tm-chain-migration-runbook.md`; still one config Update
epoch, no bridge redeployment:

1. Build the new TM script (hash changes) → new peg-in hash (parameter) → new
   peg_out hash (rewrite) → trie validator hash (parameterized by the new TM
   hash).
2. One-shot mint the fulfilled-trie UTxO (empty root).
3. Config Update: swap field 3 (→ the fulfilled-trie policy id), swap
   field 4 (peg-in withdraw hash), swap field 5 (peg-out withdraw hash),
   field 11 anchor as already planned. Register the new peg-in and peg-out
   reward accounts.
4. Existing PORs at the old peg-out address (if any) predate the new scheme
   and are handled before the switch. The old completed-peg-outs UTxO is
   abandoned in place. It has in fact been unspendable since bootstrap: its
   spend gate needs the old `CompletePegOut` to validate, which needs the
   `produced`-verifier withdrawal, which is a dummy hash with no script. The
   field-5 swap only adds a second lock (the new redeemer shape never decodes
   as the old one). ~2 ADA stranded, accepted. It cannot be repurposed as the
   FPO trie: its validator delegates every continuation check (root, NFT,
   address) to the old `peg-out.ak` logic being deleted, so any tx that
   satisfied its gate could take the NFT and write an arbitrary root.

### Documentation updates (per the traceability rules)

- §Complete peg-out: mark [CPO-1], [CPO-2], [CPO-4]–[CPO-8] **withdrawn**
  (superseded by this design); keep [CPO-3] (owner_auth), [CPO-9] (exact
  burn), [CPO-10] (min-ADA return); add fresh IDs (continue numbering,
  [CPO-11]+) for the membership + value-binding checks.
- §Cancel PegOut request: mark [CXL-1]–[CXL-4] withdrawn; keep [CXL-5]/[CXL-6];
  add fresh IDs for the timeout and exclusion checks.
- §Create PegOut request: new datum table (drop `source_chain_treasury_utxo_id`
  and its footgun warnings, add `created`), updated client-side checks.
- §Confirm TM tx: add the trie-update checks with new [CTM-*] IDs; fix the
  "peg-out completion … verifies the raw TM directly against Binocular"
  statement; TM structure gains the marker-pair layout.
- §Treasury Movement Transaction / UTxO map / Config table (field 3
  re-documented as the fulfilled-peg-outs trie) / parameter registry; note
  fields 7/8 vestigial and the old completed-peg-outs UTxO abandoned.

### Decisions (defaults adopted; flag to flip)

- **Trie key = POR id + per-peg-out OP_RETURN markers** (user-selected;
  markers-after-each-output and the `"POR"` prefix per review — 80-byte
  standardness and the `"BFR"` beacon-scan collision). Fallback
  `(spk, amount)` keying rejected: insert collisions would permanently stall
  the TM chain and identical repeat peg-outs would be impossible.
- **POR identity/created = plain UTxO + SPO freshness filter** (no POR mint
  policy). The margin filter fully covers backdating; a PIR-style mint-gated
  POR NFT (anchoring `created` at the validity bound) remains the upgrade path
  if an on-chain guarantee is later wanted.
- **Completed-peg-outs trie retired; its config slot (field 3) repurposed.**
  POR ids are unique and a POR UTxO spends exactly once, so double-completion
  is impossible without the completion-side trie; dropping it removes the
  per-Complete singleton contention. After the peg-out rewrite NO on-chain
  reader of field 3 remains (verified: old `peg-out.ak` was the only one), so
  the migration swaps its value to the new trie policy instead of appending a
  field 17 — the binocular `ConfigDatum` mirror stays 17 fields and decodes
  pre- and post-migration configs alike. The old trie UTxO itself CANNOT be
  reused: its deployed validator gates spends on a `peg_out` withdraw run with
  a `CompletePegOut` action, and a TM Confirm tx cannot run that withdraw (no
  peg-out input at its credential) — hence the new TM-transition-gated
  validator and a fresh trie UTxO (asset name `"FPO"`, distinct from the
  abandoned `"CPO"` UTxO for indexer clarity). The old UTxO is abandoned in
  place with no config pointer, and its validator source is DELETED from the
  tree (with the `"CPO"` constant and the deploy bootstrap): after the
  field-5 swap its spend gate can never be satisfied again (old-shape
  redeemer decode), so keeping compilable-but-unusable source would only
  mislead readers — the 7b7a7ee precedent.
- **Cancel timeout = 30-day validator constant** (like `GcGraceMs`), not a
  config field. SPO margin 7 days. Tunable only by a peg_out script swap via
  config Update (field 5), which is acceptable given the config-swap machinery
  now exists.

### Residual risks and properties (accepted)

- SPOs paying a peg-out on Bitcoin but the TM never confirming on Cardano
  within the cancel window would allow a double-claim; identical in kind to
  the TM-chain liveness assumption, bounded by the 23-day gap between margin
  and timeout (confirm latency is hours).
- An SPO quorum omitting a fulfilled peg-out's marker (or mislabeling it)
  burns treasury BTC without closing the POR — SPO fraud/bug territory, same
  trust class as treasury custody itself; the `AlreadyPresent` tolerance and
  heimdall dedup keep it from ever stalling the chain.
- Trie continuity is independent of TM-chain re-anchors: POR ids carry no
  chain state, so a governance re-anchor of Config #11 (e.g. after a
  federation sweep) leaves every past insertion and pending cancel/complete
  proof valid.

### Testing

- Scalus: confirm-path suites for the trie fold (happy, multi-peg-out,
  zero-peg-out, `AlreadyPresent`, wrong value, odd output count, malformed /
  wrong-prefix marker, missing trie spend, forged trie NFT, wrong final
  root).
- Aiken: `peg-out.ak` Complete/Cancel suites (membership value binding, fee
  arithmetic, timeout boundary, exclusion proof, owner auth, burn exactness,
  no-mint-on-cancel); trie validator suites (bootstrap one-shot, spend gated
  on TM transition, constr-tag checks); config getter pin test for the renamed field 3.
- heimdall: builder marker-pair determinism, freshness filter boundaries, id
  hashing golden vectors against Aiken's `hash_output_ref`.
