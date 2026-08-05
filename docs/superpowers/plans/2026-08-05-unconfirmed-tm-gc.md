# Unconfirmed TM Garbage Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a TM record's creator reclaim an `Unconfirmed` record that will
never confirm (failed broadcast, RBF'd tx, lost outpoint race, test post),
under the same rule the `Confirmed` GC path already uses, and ship the CLI
tooling that neither path has ever had.
Spec: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`
§Addendum rev 5.3.

**Architecture:** One repo. The change is confined to binocular's Scalus TM
validator (spend dispatch + a shared GC rule) plus a new CLI command; the
Aiken tree, heimdall, and every datum shape are untouched. The ft repo gets
documentation only.

## Global Constraints

- NEVER commit inside `ft-bifrost-bridge/offchain/*` submodule checkouts —
  commit in `/Users/nau/projects/lantr/binocular`, then bump the submodule
  ref in ft.
- No Claude co-author trailers. No em dashes in commit messages.
- binocular: `sbt "testOnly *"` (428 green at base `a827d54`), scalafmt clean.
- The TM script hash WILL change. Consequences to carry: the peg-in
  `tm_nft_policy_id` parameter value, the CPO trie validator's
  `tm_nft_policy_id` parameter, the blueprint pins, and the migration runbook
  (the migration is still unexecuted, so this is a rebuild, not a redeploy).
- Rules fixed by the spec: `UnconfirmedGcGraceMs = 86_400_000` (1 day);
  `GcGraceMs` (30 days) unchanged for `Confirmed`; GC requires mint `-1`,
  `tmInputCount == 1`, creator signature, and validity entirely after the
  deadline; one record per transaction (no batching).

---

### Task 1: Scalus — spend redeemer dispatch + Unconfirmed GC

**Files:**
- Modify: `src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`,
  `src/main/scala/binocular/watchtower/TreasuryMovementTx.scala` (wrap the
  confirm redeemer)
- Test: `src/test/scala/binocular/TreasuryMovementValidatorTest.scala`

**Interfaces:**
- Produces: `enum TmSpendRedeemer derives FromData, ToData { case Confirm(proof:
  TmConfirmRedeemer); case Gc }` with an `@Compile` companion;
  `val UnconfirmedGcGraceMs: BigInt = BigInt(24) * 3600 * 1000`; a shared
  `inline def validateGc(creator, created, graceMs, tx, ownRef)` used by both
  datum branches. `TmConfirmRedeemer`, `TmDatum`, and `TmMintRedeemer` shapes
  are UNCHANGED.

- [ ] **Step 1: Extract the GC rule.** Lift the four checks out of the
  `Confirmed` branch into `validateGc`, parameterized by the grace period:
  own-script credential; `tx.mint.quantityOf(ownScriptHash, empty) == -1`
  ("Must burn TM NFT"); `tmInputCount(tx.inputs, ownScriptHash) == 1`
  ("TM GC: exactly one TM-script input per tx");
  `tx.validRange.isEntirelyAfter(created + graceMs)` ("TM GC: grace period has
  not elapsed"); `tx.isSignedBy(creator)` ("TM GC: not signed by the record's
  creator"). Keep the existing message strings verbatim so the reason-pinned
  tests keep working.
- [ ] **Step 2: Redeemer enum + dispatch.** Add `TmSpendRedeemer`. In
  `spend`, decode it once; `Unconfirmed` dispatches
  `Confirm(proof)` → the existing confirm logic (unchanged, including the
  CPOR1 root copy), `Gc` → `validateGc(..., UnconfirmedGcGraceMs)`;
  `Confirmed` requires `Gc` (`case _ => fail("TM spend: a Confirmed record is
  spendable only by GC")`) then `validateGc(..., GcGraceMs)`. Scaladoc: why
  the two periods differ (the spec's Why note — third parties depend on a
  Confirmed record, nobody depends on an Unconfirmed one), and that GC can
  never touch the CPO trie (its validator needs a tag-1 output).
- [ ] **Step 3: CLI wrap.** `ConfirmTmtxCommand` / `TreasuryMovementTx` build
  `TmSpendRedeemer.Confirm(existing redeemer)`. No other logic changes.
- [ ] **Step 4: Tests** (keep the `assertRejects` reason-pinning):
  Unconfirmed GC — happy path; before the deadline fails; wrong signer fails;
  no burn fails; burn of +1/-2 fails; two TM inputs fail; a GC tx that also
  tries to spend the CPO trie fails (the trie validator has no tag-1 output —
  assert at the TM validator level that the GC path needs no trie at all, and
  that the confirm path still does). Confirmed GC — unchanged behaviour under
  the new redeemer, still 30 days (a Confirmed record at day 2 must FAIL,
  proving the periods did not get swapped). Confirm path — unchanged, now
  wrapped; a `Gc` redeemer on an Unconfirmed record with a valid oracle proof
  must still be judged by GC rules only.
- [ ] **Step 5:** `sbt "testOnly *"` + scalafmt + blueprint pin refresh (the
  TM hash moves; the pin-freshness test will fail until refreshed).
- [ ] **Step 6: Commit** —
  `feat(tm): let a creator GC an Unconfirmed record after a 1-day grace`

---

### Task 2: binocular — `gc-tmtx` command

**Files:**
- Create: `src/main/scala/binocular/cli/commands/GcTmtxCommand.scala`
- Modify: `src/main/scala/binocular/cli/CliApp.scala` (subcommand wiring)
- Test: a new suite for the selection/eligibility logic

**Interfaces:**
- Produces: `gc-tmtx [--dry-run] [--older-than <duration>] [--limit N]` —
  scans the TM address, decodes each record, keeps those whose `creator`
  equals the wallet's payment key hash and whose deadline
  (`created + 1 day` for `Unconfirmed`, `created + 30 days` for `Confirmed`)
  has passed, and submits ONE transaction per record: spend the record with
  `TmSpendRedeemer.Gc`, burn the TM NFT, set `validFrom` past the deadline,
  require the creator signature, min-ADA to the wallet.

- [ ] **Step 1:** Selection + eligibility as a pure function over
  `(records, walletPkh, now)` returning eligible / skipped-with-reason —
  unit-testable without a provider.
- [ ] **Step 2:** Transaction builder + submission loop with per-record error
  isolation; print a table (record, variant, created, deadline, action).
  SAFETY: refuse to GC a `Confirmed` record that is the CHAIN TIP (the
  standing operational rule) — detect it as the Confirmed record no other
  record chains from, and require an explicit `--force-tip` to override.
- [ ] **Step 3:** Tests for eligibility (both variants, boundary at the
  deadline, foreign creator skipped, tip protection). Transaction assembly is
  compile-only unless the repo's emulator harness reaches it — state which in
  the report.
- [ ] **Step 4:** `sbt "testOnly *"` + scalafmt. **Commit** —
  `feat(cli): gc-tmtx - reclaim TM records past their grace period`

---

### Task 3: Documentation

**Files:**
- Modify: `documentation/technical_documentation.md`,
  `documentation/tm-chain-migration-runbook.md` (ft repo)

- [ ] **Step 1:** §Confirm TM tx / the TM GC section: document the spend
  redeemer (`Confirm` | `Gc`) and add fresh check IDs continuing the [CTM-*]
  sequence for the Unconfirmed GC rule (burn, single input, creator, 1-day
  deadline). Never renumber; the existing Confirmed-GC IDs keep their
  meaning, with their grace period restated as 30 days.
- [ ] **Step 2:** UTxO map: the `Unconfirmed` TM row changes from
  permanently locked to "reclaimable by the creator after 1 day"; state the
  two periods and the Why note (third-party dependence) in one place.
- [ ] **Step 3:** The TM-chain lifecycle mermaid diagram: add a GC edge from
  the `Unconfirmed` node (labelled with the 1-day rule) alongside the
  existing Confirmed-GC edge. Single-line labels, no semicolons; verify it
  parses.
- [ ] **Step 4:** Runbook: `gc-tmtx` in the operator toolbox, the tip rule,
  and a note that the TM script hash changed (rebuild peg-in + trie
  parameters before the migration is executed).
- [ ] **Step 5: Commit** — `docs(spec): GC of Unconfirmed TM records`

---

### Task 4: Submodule bump + verification

- [ ] Push binocular; bump `offchain/bitcoin-watchtower/binocular` in ft;
  full sweep (`aiken check`, `sbt "testOnly *"`, heimdall `cargo test` as a
  regression check even though it is untouched); push ft.

---

### Open decisions (flag to flip before execution)

- **1-day grace for Unconfirmed** (vs 30-day symmetry, vs zero). Chosen
  because nothing third-party depends on an Unconfirmed record and Confirm is
  permissionlessly re-enabled by re-posting; the day forecloses a
  confirm-race grief window and keeps test cleanup practical.
- **Explicit `TmSpendRedeemer`** (vs inferring intent from the mint sign).
  Chosen for auditability and symmetry with `TmMintRedeemer`; costs one
  wrapping change in the confirm builder.
- **No batching.** `tmInputCount == 1` is the NFT-containment invariant;
  batching would require replacing it with per-transaction burn accounting.
