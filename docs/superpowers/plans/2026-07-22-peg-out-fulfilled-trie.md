# Peg-Out Attested-Root Implementation Plan (rev 5.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the approved rev-5.1 design: the FROST-signed TM commits the
updated CPO root in one `"CPOR1"` OP_RETURN; TM Confirm copies it into the
CPO singleton (O(1)); peg-out Complete is permissionless value-bound
membership + burn; Cancel is owner + 30 d + non-membership; the DA hint is an
appended `Unconfirmed`-datum field; heimdall attests, hints, and reconstructs
via the self-hosted Dolos/Kupo stack.
Spec: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`
(rev 5.1, Approved).

**State:** Tasks 1–4 of the rev-3 plan are LANDED and partially carry over:

- Task 1 (`completed-peg-outs-merkle-tree.ak` rewrite, ft `48af40b`):
  survives VERBATIM (tag checks are arity-blind).
- Task 2 (`peg-out.ak` rewrite, ft `e73d3bf`): survives; rev 5.1 changes one
  check (Task 5).
- Task 3 (Scalus confirm fold, binocular `c936d78`+`40298ba`): the marker
  walk + MPF fold + `PegOutTrieStep` machinery is REPLACED by root-copy
  (Task 6); trie in/out plumbing, config read, containment checks, and test
  scaffolding carry over.
- Task 4 (binocular CLI, `bdaf0f9`+`632caca`): bootstrap command, config
  swap flags, blueprint-resource work, BifrostContracts updates survive;
  ConfirmTmtx proof generation is replaced by root extraction (Task 6). The
  pending scoped re-review of `632caca` is folded into Task 6's review
  (same files, superseded logic).

## Global Constraints

- NEVER commit inside `ft-bifrost-bridge/offchain/*` submodule checkouts — commit
  in `/Users/nau/projects/lantr/binocular` and `/Users/nau/projects/lantr/heimdall`,
  then bump the submodule refs in the main repo.
- No Claude co-author trailers in commit messages. No em dashes in prose.
- binocular: `sbt "testOnly *"` (366 green at base `632caca`); scalafmt clean.
- heimdall: `nix develop --command env RUSTC_BOOTSTRAP=1 cargo test`.
- Aiken from `onchain/`: `nix develop --command aiken check` (+ `aiken build`
  when the blueprint must regenerate). 102 tests green at base.
- Spec constants: CPO NFT asset name `"CPO"`; root commitment scriptPubKey =
  `6a2543504f5231 ++ root` (39 bytes, tag `"CPOR1"`, root = spk[7, 39));
  EXACTLY ONE commitment output per TM; trie value `dest_spk ++ amount_le8`
  (LE); `por_id = sha2_256(serialise_data(OutputReference))`; cancel timeout
  2_592_000_000 ms; freshness margin default 7 days; DA hint =
  `fulfilled_por_outpoints: List<ByteArray>` APPENDED to `Unconfirmed`
  (36-byte Cardano outpoints, txid ++ vout LE), unverified on-chain;
  `Confirmed` stays 8 fields; `fulfilledPegOuts` content KEPT (heimdall's
  treasury-value source).
- Config shape untouched; migration swaps field VALUES only (3/4/5, 11).

---

### Task 5: Aiken — permissionless Complete + 6-field Unconfirmed mirror

**Files:**
- Modify: `onchain/validators/bitcoin/peg-out.ak` (+ its tests, same file)
- Modify: `onchain/lib/bifrost/types/treasury-movement.ak`

**Interfaces:**
- Produces: `CompletePegOut` branch WITHOUT the `owner_auth` check — its
  `and` block becomes `{ fulfilled_proven, all_bridged_tokens_burnt }`;
  `Cancel` unchanged. `TreasuryMovementDatum.Unconfirmed` gains the appended
  field `fulfilled_por_outpoints: List<ByteArray>` (mirror discipline: full
  arity, in lock-step with the Scalus change in Task 6).

- [ ] **Step 1:** In `peg-out.ak`, remove `user_authorized` from the
  `CompletePegOut` branch only; move the binding into the `Cancel` branch
  (its sole remaining user). Update comments: completion is permissionless
  cleanup — it can only burn the exact locked fBTC against a value-bound
  attested payment, so authorization adds nothing; the completer keeps the
  MIN_ADA; the root is quorum-attested at TM Confirm (spec rev 5.1).
- [ ] **Step 2:** In `treasury-movement.ak`, append to `Unconfirmed`:

```aiken
    //DA hint (rev 5.1): Cardano outpoints (36 B = tx hash ++ vout LE) of the
    //PegOutRequests this TM fulfills. UNVERIFIED on-chain - the FROST-signed
    //CPOR1 root committed in signed_btc_tx is the integrity anchor; this
    //field only lets reconstruction skip the search fallback.
    fulfilled_por_outpoints: List<ByteArray>,
```
  and update the header comment's Scalus-shape listing (Unconfirmed now
  6 fields). `Confirmed` untouched.
- [ ] **Step 3:** Tests: change `complete_rejects_unauthorized` into
  `complete_by_third_party_succeeds` (same fixture, non-owner signer,
  expect True). Keep `cancel_rejects_unauthorized`. All other tests
  unchanged.
- [ ] **Step 4:** `aiken check` (expect 102 green) then `aiken build`
  (peg_out hash changes in plutus.json).
- [ ] **Step 5: Commit** —
  `feat(onchain): permissionless peg-out completion + 6-field Unconfirmed mirror`

---

### Task 6: binocular — Confirm copies the attested CPOR1 root

**Files:**
- Modify: `src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`,
  `src/main/scala/binocular/cli/commands/CreateTmtxCommand.scala`,
  `src/main/scala/binocular/watchtower/TreasuryMovementTx.scala`,
  `src/main/scala/binocular/watchtower/CompletedPegOutsTrie.scala` (repurpose)
- Test: `TreasuryMovementValidatorTest.scala`, `CompletedPegOutsTrieTest.scala`
- Refresh blueprint pins (TM script hash changes; the pin-freshness test
  catches it).

**Interfaces:**
- Produces: `TmDatum.Unconfirmed` gains appended
  `fulfilledPorOutpoints: ScalusList[ByteString]` (6th field; mint decodes
  positionally and IGNORES it — no validation; every pattern match updated).
  `Confirmed` unchanged (8 fields). `TmConfirmRedeemer` back to 4 fields —
  `pegOutSteps` and `enum PegOutTrieStep` DELETED.
  `CompletedPegOutsTrieDatum(root)` stays. New constants:
  `RootCommitmentPrefix = hex"6a2543504f5231"` (7 bytes), commitment spk
  length 39.
- Consumes: config field 3 via the existing mirror; `"CPO"` asset name.

- [ ] **Step 1: Datum.** Add the 6th `Unconfirmed` field + scaladoc (hint,
  unverified, reconstruction reads it from the spent output's inline datum).
  Update every `Unconfirmed(...)` pattern (spend/confirm branch, mint
  branch, tests, CLI builders). Mint validates nothing about it.
- [ ] **Step 2: Validator.** In the Confirm branch replace the pair walk +
  fold with: scan `fulfilled` (parsed outputs) for entries with spk size 39
  and prefix `RootCommitmentPrefix`; require exactly one (fail
  "TM confirm: missing root commitment" / "TM confirm: multiple root
  commitments"); `newRoot = spk.slice(7, 32)`. Keep config-ref + trie
  in/out location and same-address checks as they are; final check:
  `trieOut.datum.of[CompletedPegOutsTrieDatum].root == newRoot`
  ("TM confirm: trie root does not match the committed root"). Delete
  `PegOutTrieStep`, the fold, and now-unused marker helpers.
  `fulfilledPegOuts` datum construction unchanged (all outputs, inert).
- [ ] **Step 3: CLI.** ConfirmTmtx/TreasuryMovementTx: drop proof
  generation and replay gating; extract the committed root off-chain with
  the same exactly-one rule; spend + recreate the CPO singleton with the new
  root; 4-field redeemer; fix the fix-round TODO comments (the command
  confirms every well-formed TM again). CreateTmtx: 6-field datum (empty
  hint list). `CompletedPegOutsTrie`: keep root-extraction + trie-replay
  inspection helpers; delete the step builder.
- [ ] **Step 4: Tests** per the spec's Testing list: happy root-change;
  zero-peg-out (unchanged root, commitment still required); missing
  commitment; two commitments; wrong prefix; wrong-length spk; continuing
  root mismatch; missing trie spend; forged trie NFT; trie address changed;
  6-field Unconfirmed round-trip through mint and confirm (hint ignored).
  Keep `assertRejects` reason-pinning. Fixture TMs: payments + ONE
  commitment output, no markers.
- [ ] **Step 5:** Full `sbt "testOnly *"` + scalafmt; pins refreshed.
  **Commit** —
  `feat(tm): confirm copies the FROST-attested CPOR1 root (no on-chain MPF)`

---

### Task 7: heimdall — attest, hint, reconstruct (Dolos/Kupo stack)

**Files:**
- Modify: `src/bitcoin/tm_builder.rs` (commitment output; drop pin-skip)
- Create: `src/cardano/cpo_trie.rs` (trie build/persist/verify/reconstruct)
- Create: `src/cardano/kupo.rs` (minimal Kupo client: matches by address
  pattern, spent+unspent, datum resolution)
- Modify: `src/cardano/publish.rs` (6-field Unconfirmed datum with the hint
  outpoints), `src/cardano/treasury_datum.rs`, `src/cardano/blockfrost_chain.rs`
  (POR scan, 4-field PegOutDatum), `src/config.rs` (freshness margin, trie
  state path, kupo endpoint, genesis treasury value note)
- Test: alongside each module

**Interfaces:**
- Produces: `PegOutRequest { script_pubkey, amount, per_pegout_fee, por_id,
  outpoint }`; `build_tm` emits payments (sorted by spk) + ONE commitment
  output last (`script = OP_RETURN PUSH37 "CPOR1"++root`); `CpoTrie` with
  `insert_batch`, `root()`, `verify_proposed(root, entries)` (co-signer
  check wired into the FROST round validation), persistent state, and
  `reconstruct(kupo) -> CpoTrie`; publish writes the hint outpoints into the
  datum's 6th field.
- MPF implementation MUST match the Aiken/Scalus MPF hashing exactly —
  golden-test roots against a scalus-generated vector (binocular emits it;
  commit the vector file).

- [ ] **Step 1: builder** — commitment output (+43 B vsize constant);
  `por_id`/`outpoint` on `PegOutRequest`; per-request pinned fee in the
  dust/net math; freshness filter (`created <= now`,
  `created + CANCEL_TIMEOUT − now >= margin`); skip PORs already in the
  local trie; REMOVE the outpoint-pin skip logic; keep dust/standardness
  skips. Determinism tests (root depends only on the selected set).
- [ ] **Step 2: cpo_trie** — deterministic MPF over
  `(sha256(cbor(outpoint)) → spk ‖ le8(net))`; persistent state (existing
  state-dir pattern); `verify_proposed` for co-signers (recompute from own
  trie + the proposed TM's payment set; refuse to sign on mismatch);
  `reconstruct` per the spec algorithm: all Confirmed datums (spent+unspent)
  at the TM address → confirmed set + chain order via treasury linkage;
  matching Unconfirmed datums by recomputed txid → committed root + hint;
  resolve hint outpoints via Kupo → entries; per-TM running-root assertion;
  fallback matcher on garbled hints. por_id golden vector vs Aiken's
  `hash_output_ref`.
- [ ] **Step 3: publish + scan** — 6-field Unconfirmed datum (hint
  outpoints); POR scanner parses the 4-field PegOutDatum; steady-state
  queries stay within the Dolos-servable (blockfrost-compatible) subset —
  note each endpoint used.
- [ ] **Step 4:** `cargo test` full suite green. **Commit** —
  `feat(pegout): attested CPOR1 root - build, co-sign verify, datum hint, Kupo reconstruction`

---

### Task 8: Documentation + runbook

NOTE: the working tree holds an UNCOMMITTED TM-chain lifecycle mermaid
flowchart in `technical_documentation.md` (before §Confirm TM tx), authored
by the user. PRESERVE it (never clobber or duplicate), update its Confirm
edge to rev 5.1 (the Confirm also spends the CPO singleton — attested-root
copy) and its Unconfirmed datum line (gains `fulfilled_por_outpoints`), and
let it commit together with the doc changes.

Per the spec's §Documentation updates: new §Infrastructure assumptions block
(normative, incl. the genesis treasury-value note); Complete/Cancel catalog
rewrites with the withdrawn/kept/fresh check IDs ([CPO-3] withdrawn too —
permissionless completion, rationale recorded); Create PegOut datum table;
Confirm TM tx [CTM-*] root-commitment checks; Post signed TM: the
`fulfilled_por_outpoints` datum field + TM structure (CPOR1 commitment
output, no markers); Config row 3 semantics; fields 7/8 vestigial; stale
Config #15 note; UTxO map; parameter registry. Runbook: trie bootstrap +
one-Update field swaps (3/4/5, 11 optional keep-current), ordering note
(singleton + field 3 before first new-script Confirm), GC decoupled from
peg-outs. Spec Status already Approved.

**Commit** — `docs(spec): peg-out termination via the attested CPOR1 root`

---

### Task 10: heimdall — Kupo optional, Blockfrost-API reconstruction backend

**Files:**
- Modify: `src/cardano/cpo_trie.rs` (history-provider abstraction),
  `src/cardano/kupo.rs`, `src/cardano/bf_http.rs` / `blockfrost_chain.rs`
  (history endpoints), `src/config.rs` (kupo endpoint optional), CLI wiring
  for `reconstruct-cpo-trie`
- Modify: `documentation/technical_documentation.md` §Infrastructure
  assumptions (one edit: Kupo optional, Blockfrost-API fallback — mirror the
  spec's rev 5.2 wording)

**Interfaces:**
- Produces: one reconstruction interface with two backends — Kupo (existing)
  and Blockfrost-compatible (`GET /addresses/{addr}/transactions` paginated
  + `GET /txs/{hash}/utxos` + datum resolution) — selected by config: Kupo
  endpoint present → Kupo, absent → Blockfrost path. Identical
  reconstruction semantics (hard-error on gaps, per-TM root assertion,
  multi-hint trial, fallback matcher, on-chain root cross-check) in BOTH
  backends — share the algorithm, vary only the fetch layer.

- [ ] Step 1: extract the fetch layer behind a trait (matches with datums,
  spent+unspent, for an address; resolve outpoint → output+datum); implement
  the Blockfrost backend over address-tx-history walking.
- [ ] Step 2: config: `kupo_endpoint` optional; selection logic + log line
  naming the active backend.
- [ ] Step 3: tests — backend-shared algorithm tests stay; add a
  Blockfrost-backend fixture test (mocked HTTP or trait-level fake); full
  suite green.
- [ ] Step 4: the one-paragraph tech-doc edit. Commit —
  `feat(pegout): Blockfrost-API reconstruction backend - Kupo optional`

---

### Task 11: binocular — watchtower POR sweeper (Confirm -> Complete chaining)

**Files:**
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`
  (post-confirm hook), watchtower loop wiring
- Create/rewrite: peg-out completion builder (replaces the stale
  `PegOutCompleteCommand` flow) + persistent local trie mirror
- Modify: `src/main/scala/binocular/watchtower/CompletedPegOutsTrie.scala`
  (proof building from the mirror), `BridgeConfig` (peg-out script params /
  sweeper toggle)
- Test: proof-builder + sweeper-decision tests; tx-shape tests as feasible

**Interfaces:**
- Produces: after each successful confirm, the watchtower: (1) updates its
  persistent trie mirror from the confirmed TM's hint outpoints + attested
  root (hard-verify: mirror root == committed root, else halt sweeping and
  log — reconstruction needed); (2) for each fulfilled POR still unspent,
  builds ONE Complete tx: spend the POR with the peg-out spend handler,
  invoke the peg-out withdraw with
  `{config_ref_input_index, completed_peg_outs_ref_input_index,
  CompletePegOut{membership_proof}}`, reference inputs = Config UTxO + CPO
  singleton, burn all locked fBTC under the bridged-token policy, MIN_ADA +
  residue to the watchtower wallet; submits them independently (parallel,
  no contention). Cold-start mirror: reconstruct from chain history via the
  provider (Confirmed records + spent Unconfirmed datums' hints, root-
  verified per TM) — Blockfrost-served, no Kupo requirement.
- Consumes: `peg_out_validator` 2-param blueprint from ft plutus.json (via
  BifrostContracts), `CompletedPegOutsTrie.trieFrom`, the 4-field
  PegOutDatum, bridged-token policy from Config fields 0/1.

- [ ] Step 1: persistent trie mirror (state file; update-at-confirm;
  cold-start reconstruction; root verification gates).
- [ ] Step 2: Complete tx builder + membership proof from the mirror;
  emulator/CEK test against the real Aiken peg_out blueprint if feasible,
  else tx-shape unit tests + document what is compile-only.
- [ ] Step 3: watchtower chaining — after confirm success, sweep loop with
  per-POR error isolation (one failed complete must not block the rest),
  dry-run support, config toggle (default on).
- [ ] Step 4: full suite + scalafmt + pins; runbook/doc touch: replace the
  two hedged runbook spots from Task 8 (exact completion command name; note
  the sweeper automates it). Commit —
  `feat(watchtower): POR sweeper - chain Complete after Confirm`

---

### Task 9 (runs LAST): Submodule bumps + end-to-end verification

- [ ] Push binocular and heimdall; bump both submodule refs in
  ft-bifrost-bridge; full three-repo verification sweep (`aiken check`,
  `sbt "testOnly *"`, `cargo test`); push main.

---

### Tracked follow-ups (out of plan scope)

- `PegOutRequestCommand` refresh (4-field datum) if still stale after
  Task 11.
- `BitcoinContract` blueprint pin freshness test (oracle side).
- Pre-existing peg_in blueprint pin drift — resolve before next deploy.
- Deferred minors in the SDD ledger.
