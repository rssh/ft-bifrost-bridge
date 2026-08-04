# Peg-Out Termination via the Completed-Peg-Outs Trie (OP_RETURN-committed POR ids)

Date: 2026-07-22 (rev 3 — the trie keeps the protocol's existing identity:
name, `"CPO"` asset name, config field 3. Earlier revisions of this file
called it the "fulfilled-peg-outs trie"; the file name keeps that working
title, the design does not.)
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
   (paying outpoint already claimed in the trie, [CPO-7]) nor cancel (an
   output paying `(dest, amount)` exists, so [CXL-4] is unprovable). fBTC
   locked forever.
4. **Poor liveness.** A POR is only fulfillable by the single TM spending its
   pinned tip; every request that misses its TM window must cancel, re-create,
   and re-pin, repeatedly and under contention.

## Design

### Core idea

The **completed-peg-outs trie** (the existing NFT-authenticated singleton:
asset name `"CPO"`, policy id in config field 3) changes what it records and
when. It becomes the set of every peg-out **paid by a confirmed TM**, keyed by
**POR id**, and it is written at **TM Confirm** — not at peg-out Complete. The
TM Bitcoin transaction itself commits, in FROST-signed **OP_RETURN marker
outputs** (one per peg-out), which POR each peg-out output fulfills. The TM
Confirm transition inserts those entries; peg-out Complete proves membership
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
`treasury-movement.ak` / heimdall parsers. `ConfigTypes.scala` is untouched —
the trie policy is read from the existing mirror field
`completedPegOutsMerkleTreePolicyId` (field 3).

The Confirm spend branch gains, on top of its current checks (oracle proof,
datum reconstruction, federation-leaf flag):

1. Locate the Config UTxO among reference inputs (by config NFT — parameters
   already applied) and read field 3, the completed-peg-outs trie policy id.
2. Require the trie UTxO (its NFT, asset name `"CPO"`) to be **spent** in this
   tx, with a continuing output carrying the NFT at the same address.
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

**`completed-peg-outs-merkle-tree.ak` rewritten in place** (same file, same
datum `{root}`, same `"CPO"` asset name, same one-shot bootstrap mint; new
parameterization and a new spend gate):

- Parameters become `(tm_nft_policy_id: ByteArray, one_shot_input_ref:
  OutputReference)` — the config NFT parameters go (the old spend read the
  peg_out hash from config field 5; the new spend reads nothing from config).
- `mint`: unchanged one-shot bootstrap — empty MPF root, NFT to its own
  script address.
- `spend`: permitted iff the same tx performs a TM Confirm transition: an
  input carrying the TM NFT (policy = the `tm_nft_policy_id` parameter, empty
  asset name) whose inline datum is Constr **0** (Unconfirmed), and an output
  carrying that NFT with datum Constr **1** (Confirmed). Constructor-tag
  checks on raw Data only — no field decoding, so no arity coupling to the
  Scalus datum shape. Root/value/address correctness of the continuation is
  enforced by the Scalus confirm branch in the same tx (the same
  delegation-by-pairing the old design used toward `peg_out.ak`).

**`peg-out.ak` rewrite** (dramatic simplification — the oracle input, both
verifier delegations, and all SPV proof plumbing are deleted):

- `PegOutDatum` becomes
  `{owner_auth, source_chain_destination_address, per_pegout_fee, created}` —
  `source_chain_treasury_utxo_id` dropped (nothing to pin; this also deletes
  the two "permanently unrecoverable" client-side footguns tied to it),
  `per_pegout_fee` pinned at lock time from Config #13 as already normative in
  the doc, `created` (POSIX ms) added for the cancel timeout.
- New constant `peg_out_cancel_timeout_ms = 30 * 24 * 3600 * 1000` (30 days).
- `withdraw` redeemer: `{config_ref_input_index,
  completed_peg_outs_ref_input_index, action}` with
  `action = CompletePegOut{membership_proof} | Cancel{exclusion_proof}`.
- Shared: read config (field 3 → trie NFT policy, via the existing getter);
  the trie is a **reference input** (found at the given index, authenticated
  by its NFT) — Complete/Cancel never spend the singleton, removing that
  contention; `por_id = utils.hash_output_ref(peg_out_input.output_reference)`;
  `owner_auth` authorization as today.
- `CompletePegOut`: `mpf.has(trie_root, por_id,
  dest_script_pub_key ++ int_to_le8(fbtc_amount - per_pegout_fee), proof)`;
  all locked fBTC burnt (exact negative mint), as today. Complete performs
  **no trie insert** — once-only completion is structural (unique POR id,
  single-spend POR UTxO, one marker per paying output).
- `Cancel`: the spend MUST be authorized per the datum's `owner_auth` (same
  gate as Complete — only the requester can cancel); tx validity interval
  entirely after `created + peg_out_cancel_timeout_ms`;
  `mpf.miss(trie_root, por_id, proof)`; `no_bridged_token_mint` (quantity 0)
  retained — it keeps bridged-token's presence-only burn delegation sound.
- `spend` handler: unchanged own-withdraw delegation.
- A stale-trie Cancel race is structurally impossible on-chain: referencing the
  trie UTxO pins its current state (a spent trie outpoint cannot be
  referenced), and the deeper signed-but-unconfirmed-TM race is closed by the
  SPO freshness margin (below).

**Unchanged**: `types/config.ak` and `constants.ak` (field 3 and `"CPO"` keep
their names; only field 3's VALUE changes at migration — a comment on the
field notes the v2 semantics), `peg-in.ak` sources (only its applied
`tm_nft_policy_id` parameter value moves), `bridged-token.ak` (presence-only
delegation to the peg-out withdraw script — the peg_out hash it reads comes
from config field 5, swapped by the migration), `treasury.ak` (FederationReset
reads `spent_via_federation_leaf` — orthogonal; if an emergency federation TM
also fulfills peg-outs, the same marker scheme applies with no special case).

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
  already in the trie (dedup against double-fulfillment, which the on-chain
  `AlreadyPresent` tolerance additionally defuses).
- `publish.rs` / confirm flow: the TM Confirm tx now also spends the trie
  UTxO and supplies the MPF step proofs (off-chain MPF maintained from the
  trie datum history / recomputed from Confirmed records).

### Off-chain: binocular

- `ConfirmTmtxCommand`: build the extended confirm tx — spend the trie UTxO,
  compute insert proofs, extended `TmConfirmRedeemer`.
- `DeployBridgeCommand`: bootstrap the trie with the rewritten validator
  (new parameterization: TM script hash + one-shot ref).
- `UpdateConfigCommand`: swap field 3 (new trie policy) and field 5 (new
  peg_out hash) for the live migration.
- Validator tests: marker parsing, pair walk, insert fold, `AlreadyPresent`
  path, missing/wrong trie input, malformed marker / odd output count /
  wrong-prefix tags, zero-peg-out TMs.

### Migration (fold into the still-unexecuted preprod migration)

Extends `documentation/tm-chain-migration-runbook.md`; still one config Update
epoch, no bridge redeployment:

1. Build the new TM script (hash changes) → new peg-in hash (parameter) → new
   peg_out hash (rewrite) → new trie script hash (rewritten validator,
   parameterized by the new TM hash).
2. One-shot mint the new completed-peg-outs trie UTxO (empty root).
3. Config Update: swap field 3 (→ the new trie policy id), swap field 4
   (peg-in withdraw hash), swap field 5 (peg-out withdraw hash), field 11
   anchor as already planned. Register the new peg-in and peg-out reward
   accounts.
4. Existing PORs at the old peg-out address (if any) predate the new scheme
   and are handled before the switch. The old trie UTxO instance is abandoned
   in place (it was never spendable — its gate chains through the dummy
   `produced` verifier; ~2 ADA stranded, accepted).

### Documentation updates (per the traceability rules)

- §Completed-peg-outs trie / UTxO map: re-specify the trie — written at TM
  Confirm, keyed by POR id, value `dest_spk ++ amount_le8`; Complete/Cancel
  reference it, never spend it.
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
  statement; §Treasury Movement Transaction gains the marker-pair layout;
  stale Config #15 implementation-status note (N7 fields exist) corrected in
  passing.
- Config table: field 3 keeps its name; row text gains the v2 semantics +
  migration value swap. Fields 7/8 marked vestigial. Parameter registry rows
  accordingly.

### Decisions (defaults adopted; flag to flip)

- **Trie key = POR id + per-peg-out OP_RETURN markers** (user-selected;
  markers-after-each-output and the `"POR"` prefix per review — 80-byte
  standardness and the `"BFR"` beacon-scan collision). Fallback
  `(spk, amount)` keying rejected: insert collisions would permanently stall
  the TM chain and identical repeat peg-outs would be impossible.
- **The trie keeps the protocol's existing identity** (user-selected): name
  "completed-peg-outs trie", asset name `"CPO"`, config field 3 (name, getter,
  position, type all unchanged — only the VALUE is swapped at migration to the
  rewritten validator's hash). No parallel "fulfilled" concept. The deployed
  old instance cannot be upgraded in place (immutable script whose gate
  delegates continuation checks to the old `peg-out.ak`), so the migration
  bootstraps a fresh UTxO under the rewritten validator.
- **POR identity/created = plain UTxO + SPO freshness filter** (no POR mint
  policy). The margin filter fully covers backdating; a PIR-style mint-gated
  POR NFT (anchoring `created` at the validity bound) remains the upgrade path
  if an on-chain guarantee is later wanted.
- **Complete performs no trie write.** The trie is written at TM Confirm only;
  Complete/Cancel use it as a reference input, removing the per-Complete
  singleton contention of the old design.
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
  on TM transition, constr-tag checks).
- heimdall: builder marker-pair determinism, freshness filter boundaries, id
  hashing golden vectors against Aiken's `hash_output_ref`.
