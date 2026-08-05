# Peg-Out Attested-Root Implementation Plan (rev 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the rev-5 design: the FROST-signed TM commits the updated CPO
root in one OP_RETURN; TM Confirm copies it into the CPO singleton (O(1));
peg-out Complete is permissionless value-bound membership + burn; Cancel is
owner + 30 d + non-membership; heimdall maintains, attests, and reconstructs
the trie (metadata DA hint, Blockfrost only).
Spec: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md` (rev 5).

**State:** Tasks 1–4 of the rev-3 plan are LANDED and partially carry over:

- Task 1 (`completed-peg-outs-merkle-tree.ak` rewrite, ft `48af40b`):
  survives VERBATIM under rev 5.
- Task 2 (`peg-out.ak` rewrite, ft `e73d3bf`): survives; rev 5 needs one
  semantic change (Task 5 below).
- Task 3 (Scalus confirm fold, binocular `c936d78`+`40298ba`): the marker
  walk + MPF fold + `PegOutTrieStep` machinery is REPLACED by root-copy
  (Task 6 below); the trie in/out plumbing, config read, containment checks,
  and test scaffolding carry over.
- Task 4 (binocular CLI, `bdaf0f9`+`632caca`): the bootstrap command, config
  swap flags, blueprint-resource work, and BifrostContracts updates survive;
  ConfirmTmtx proof generation is replaced by root extraction (Task 6); the
  `CompletedPegOutsTrie` replay helper is repurposed as an off-chain root
  checker. The pending scoped re-review of `632caca` is folded into Task 6's
  review (same files, superseded logic).

## Global Constraints

- NEVER commit inside `ft-bifrost-bridge/offchain/*` submodule checkouts — commit
  in `/Users/nau/projects/lantr/binocular` and `/Users/nau/projects/lantr/heimdall`,
  then bump the submodule refs in the main repo.
- No Claude co-author trailers in commit messages. No em dashes in prose.
- binocular test runs: `sbt "testOnly *"` (366 tests green at base `632caca`);
  scalafmt must stay clean.
- heimdall test runs: `nix develop --command env RUSTC_BOOTSTRAP=1 cargo test`.
- Aiken runs from `onchain/`: `nix develop --command aiken check` (+ `aiken build`
  when the blueprint must regenerate). 102 tests green at base `e73d3bf`.
- Constants fixed by the spec: CPO NFT asset name `"CPO"`; root commitment
  scriptPubKey = `6a24504f5231 ++ root` (38 bytes, root = spk[6,32));
  EXACTLY ONE commitment output per TM; trie value = `dest_spk ++ amount_le8`
  (LE); `por_id = sha2_256(serialise_data(OutputReference))`; cancel timeout
  2_592_000_000 ms; freshness margin default 7 days; metadata label 4343378
  with entries `[txid_bytes32, vout_uint]`.
- Config shape untouched; migration swaps field VALUES only (3/4/5, 11).

---

### Task 5: Aiken — permissionless Complete

**Files:**
- Modify: `onchain/validators/bitcoin/peg-out.ak` (+ its tests, same file)

**Interfaces:**
- Produces: `CompletePegOut` branch WITHOUT the `owner_auth` check — its
  `and` block becomes `{ fulfilled_proven, all_bridged_tokens_burnt }`.
  `Cancel` branch and all types/redeemers unchanged.

- [ ] **Step 1:** Remove `user_authorized` from the `CompletePegOut` branch
  only. Move the `user_authorized` binding into the `Cancel` branch (it is
  now used only there). Update the file-head and branch comments: completion
  is permissionless cleanup — it can only burn the exact locked fBTC against
  a value-bound attested payment, so authorization adds nothing; the
  completer keeps the MIN_ADA as the incentive; the root is quorum-attested
  at TM Confirm (spec rev 5).
- [ ] **Step 2:** Tests: change `complete_rejects_unauthorized` into
  `complete_by_third_party_succeeds` (same fixture, non-owner signer, expect
  True). Keep `cancel_rejects_unauthorized` (non-owner cancel MUST still
  fail). All other tests unchanged.
- [ ] **Step 3:** `aiken check` (expect 102 tests, all green) then
  `aiken build` (plutus.json regenerates — peg_out hash changes).
- [ ] **Step 4: Commit** —
  `feat(onchain): permissionless peg-out completion (attested-root design)`

---

### Task 6: binocular — Confirm copies the attested root

**Files:**
- Modify: `src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`
- Modify: `src/main/scala/binocular/watchtower/CompletedPegOutsTrie.scala`
  (repurpose) and `src/main/scala/binocular/watchtower/TreasuryMovementTx.scala`
- Test: `src/test/scala/binocular/TreasuryMovementValidatorTest.scala`,
  `src/test/scala/binocular/CompletedPegOutsTrieTest.scala`
- Refresh blueprint pins per the established mechanism (TM script hash
  changes; the pin-freshness test will catch it).

**Interfaces:**
- Produces: `TmConfirmRedeemer` back to 4 fields (txIndex, txMerkleProof,
  blockMpfProof, blockHeader) — `pegOutSteps` and `enum PegOutTrieStep`
  DELETED. `CompletedPegOutsTrieDatum(root)` stays. New validator constants:
  `RootCommitmentPrefix = hex"6a24504f5231"`, script length 38.
- Consumes: config field 3 via the existing mirror; `"CPO"` asset name.

- [ ] **Step 1: Validator.** In the Confirm branch replace the pair walk +
  fold with: scan `fulfilled` (the parsed outputs, all of them) for entries
  whose scriptPubKey has size 38 and prefix `RootCommitmentPrefix`; require
  exactly one (fail "TM confirm: missing root commitment" /
  "TM confirm: multiple root commitments"); `newRoot = spk.slice(6, 32)`.
  Keep the config-ref + trie in/out location and same-address checks exactly
  as they are; replace the folded-root equality with
  `trieOut.datum.of[CompletedPegOutsTrieDatum].root == newRoot`
  ("TM confirm: trie root does not match the committed root"). Delete
  `PegOutTrieStep`, the fold, the marker helpers that are now unused
  (`isPorMarker`/`porMarkerId`/pair walk) — but KEEP any helper the tests or
  CLI still use for building TMs. `fulfilledPegOuts` datum content is
  unchanged (all outputs, inert).
- [ ] **Step 2: ConfirmTmtxCommand / TreasuryMovementTx.** Drop proof
  generation and the trie-context replay gating; extract the committed root
  from `signedBtcTx` off-chain with the same exactly-one rule; spend the CPO
  singleton and recreate it (same address/value) with the new root datum;
  4-field redeemer. Repurpose `CompletedPegOutsTrie` as the shared
  root-extraction + (kept) replay/inspection helper; delete its
  Insert/AlreadyPresent step builder. Update the accurate TODO comments from
  the fix round (the command now confirms every well-formed TM again).
- [ ] **Step 3: Tests.** Rework the trie-fold suite into the rev-5 suite per
  the spec's Testing list: happy root-change; zero-peg-out (unchanged root,
  commitment still required); missing commitment; two commitments; wrong
  prefix; wrong spk length; continuing root mismatch; missing trie spend;
  forged trie NFT; trie address changed. Keep `assertRejects` reason-pinning.
  Fixture TMs: payments + ONE commitment output (no markers).
- [ ] **Step 4:** Full `sbt "testOnly *"` + scalafmt; blueprint pins
  refreshed. **Commit** —
  `feat(tm): confirm copies the FROST-attested CPO root (no on-chain MPF)`

---

### Task 7: heimdall — attest, hint, reconstruct

**Files:**
- Modify: `src/bitcoin/tm_builder.rs` (commitment output; drop pin-skip)
- Create: `src/cardano/cpo_trie.rs` (trie build/persist/reconstruct)
- Modify: `src/cardano/publish.rs` (metadata label 4343378)
- Modify: `src/cardano/blockfrost_chain.rs`, `src/cardano/bf_http.rs`
  (tx metadata + tx utxos endpoints; POR scan with 4-field datum)
- Modify: `src/cardano/treasury_datum.rs` (datum parse), `src/config.rs`
  (freshness margin, trie state path)
- Test: alongside each module

**Interfaces:**
- Produces: `PegOutRequest { script_pubkey, amount, per_pegout_fee, por_id }`;
  `build_tm` emits payments (sorted by spk) + ONE root-commitment output
  last (`script = OP_RETURN PUSH36 "POR1"++root`); `CpoTrie` with
  `insert_batch`, `root()`, `verify_proposed(root, entries)` (co-signer
  check), `reconstruct(provider) -> CpoTrie` (chain walk + metadata hints +
  per-TM root verification + search fallback); publish attaches metadata
  `{4343378: [[txid, vout], ...]}`.
- MPF implementation: match the Aiken/Scalus MPF hashing exactly — port or
  bind; golden-test roots against a scalus-generated vector (the binocular
  repo can emit one; commit the vector file).

- [ ] **Step 1: builder** — commitment output + vsize (+43 B constant);
  `PegOutRequest.por_id`; per-request pinned fee in the dust/net math;
  freshness filter (`created <= now`,
  `created + CANCEL_TIMEOUT − now >= margin`); skip PORs already in the
  local trie; REMOVE the outpoint-pin skip logic; keep dust/standardness
  skips. Determinism tests updated (root depends only on the selected set).
- [ ] **Step 2: cpo_trie** — deterministic MPF over
  `(sha256(cbor(outpoint)) → spk ‖ le8(net))`; persistent state (heimdall's
  existing state-dir pattern); `verify_proposed` for FROST co-signers
  (recompute from own trie + proposed TM's payment set; refuse to sign on
  mismatch — wire into the signing round's validation path);
  `reconstruct`: walk Confirmed chain → confirm-tx inputs → post tx →
  metadata → POR outpoints → historical POR datum+value → insert; after
  each TM assert running root == committed root (from the post tx's inline
  datum `signedBtcTx`); fallback matcher on missing hint (match outputs to
  open PORs, search assignments, check root). por_id golden vector vs
  Aiken's `hash_output_ref`.
- [ ] **Step 3: publish + endpoints** — metadata on the Post-signed-TM tx;
  `bf_http` additions: `/txs/{hash}/metadata`, `/txs/{hash}/utxos` (if not
  present); POR scanner parses the 4-field datum.
- [ ] **Step 4:** `cargo test` full suite green. **Commit** —
  `feat(pegout): attested CPO root - build, co-sign verify, metadata DA, reconstruction`

---

### Task 8: Documentation + runbook

Per the spec's §Documentation updates: Complete/Cancel catalog rewrites with
the withdrawn/kept/fresh check IDs ([CPO-3] now withdrawn too — permissionless
completion, rationale recorded), Create PegOut datum table, Confirm TM tx
[CTM-*] root-commitment checks, TM structure (commitment output, no markers),
metadata label 4343378 under Post signed TM, Config row 3 semantics, fields
7/8 vestigial, stale Config #15 note, UTxO map, parameter registry. Runbook:
trie bootstrap + one-Update field swaps (3/4/5, 11 optional keep-current),
ordering note (singleton + field 3 before first new-script Confirm), GC now
decoupled from peg-outs (remove any sweep-before-GC rule if present). Mark
the spec Status: Approved — implemented.

**Commit** — `docs(spec): peg-out termination via the attested CPO root`

---

### Task 9: Submodule bumps + end-to-end verification

- [ ] Push binocular and heimdall; bump both submodule refs in
  ft-bifrost-bridge; full three-repo verification sweep (`aiken check`,
  `sbt "testOnly *"`, `cargo test`); push main.

---

### Tracked follow-ups (out of plan scope)

- Rewrite binocular `PegOutCompleteCommand` / `PegOutRequestCommand` against
  the new peg-out.ak (needs the reconstruction-based proof builder);
  optional completer bot.
- `BitcoinContract` blueprint pin freshness test (oracle side).
- Pre-existing peg_in blueprint pin drift — resolve before next deploy.
- Deferred minors in the SDD ledger (fee>locked doc note now moot on-chain,
  test-fixture depth, config-discovery consistency).
