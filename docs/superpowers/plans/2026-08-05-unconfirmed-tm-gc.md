# Unconfirmed TM GC + Generalized Sweeper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Let a TM record's creator reclaim an `Unconfirmed` record that
will never confirm, under the same rule the `Confirmed` GC path already uses.
(2) Unify TM-record GC and peg-out completion behind ONE generalized sweeper,
since both are the same job: reclaim the min-ADA of on-chain state that has
finished its purpose.
Spec: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`
§Addendum rev 5.3.

**Architecture:** One repo of code changes (binocular). The Scalus TM
validator gains an explicit spend redeemer and extends its GC rule to the
`Unconfirmed` variant; `PorSweeper` is generalized into a sweeper core with
two pluggable sources. The Aiken tree, heimdall, and every datum shape are
untouched. ft gets documentation only.

## Global Constraints

- NEVER commit inside `ft-bifrost-bridge/offchain/*` submodule checkouts —
  commit in `/Users/nau/projects/lantr/binocular`, then bump the submodule
  ref in ft.
- No Claude co-author trailers. No em dashes in commit messages.
- binocular: `sbt "testOnly *"` (428 green at base `a827d54`), scalafmt clean.
  Kill a long-lived sbt daemon if resource-dependent suites act stale.
- The TM script hash WILL change. Carry the consequences: the peg-in
  `tm_nft_policy_id` parameter value, the CPO trie validator's
  `tm_nft_policy_id` parameter, the blueprint pins, and the migration runbook.
  The migration is still unexecuted, so this is a rebuild, not a redeploy.
- Rules fixed by the spec: ONE grace constant, the existing
  `GcGraceMs` (30 days), for BOTH variants — no second timer. GC requires
  mint `-1`, `tmInputCount == 1`, the creator's signature, and a validity
  interval entirely after `created + GcGraceMs`. One record per transaction
  (no batching — `tmInputCount == 1` is the NFT-containment invariant).

---

### Task 1: Scalus — spend redeemer dispatch + Unconfirmed GC

**Files:**
- Modify: `src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`,
  `src/main/scala/binocular/watchtower/TreasuryMovementTx.scala` (wrap the
  confirm redeemer)
- Test: `src/test/scala/binocular/TreasuryMovementValidatorTest.scala`

**Interfaces:**
- Produces: `enum TmSpendRedeemer derives FromData, ToData { case
  Confirm(proof: TmConfirmRedeemer); case Gc }` with an `@Compile` companion;
  a shared `inline def validateGc(creator, created, tx, ownRef)` used by both
  datum branches, both with `GcGraceMs`. `TmDatum`, `TmConfirmRedeemer`, and
  `TmMintRedeemer` shapes are UNCHANGED.

- [ ] **Step 1: Extract the GC rule.** Lift the four checks out of the
  `Confirmed` branch into `validateGc`: own-script credential;
  `tx.mint.quantityOf(ownScriptHash, empty) == -1` ("Must burn TM NFT");
  `tmInputCount(tx.inputs, ownScriptHash) == 1` ("TM GC: exactly one
  TM-script input per tx"); `tx.validRange.isEntirelyAfter(created +
  GcGraceMs)` ("TM GC: grace period has not elapsed"); `tx.isSignedBy(creator)`
  ("TM GC: not signed by the record's creator"). Keep the message strings
  verbatim — the reason-pinned tests depend on them.
- [ ] **Step 2: Redeemer enum + dispatch.** Add `TmSpendRedeemer`. In
  `spend`, decode it once. `Unconfirmed`: `Confirm(proof)` runs the existing
  confirm logic unchanged (including the CPOR1 root copy), `Gc` runs
  `validateGc`. `Confirmed`: require `Gc` (`case _ => fail("TM spend: a
  Confirmed record is spendable only by GC")`), then `validateGc`. Scaladoc:
  one grace period for both variants and why (per the spec's Why note — a
  shorter one would be safe for `Unconfirmed` since nothing third-party
  depends on it, but one timer is one rule to audit); and that a GC
  transaction can never touch the CPO trie, because the trie validator's
  spend gate needs a tag-1 output and GC burns the NFT instead.
- [ ] **Step 3: CLI wrap.** `ConfirmTmtxCommand` / `TreasuryMovementTx` build
  `TmSpendRedeemer.Confirm(existing redeemer)`. No other logic change.
- [ ] **Step 4: Tests** (keep the `assertRejects` reason-pinning):
  Unconfirmed GC — happy path at day 31; day 29 fails; wrong signer fails; no
  burn fails; burn of `+1` and of `-2` fail; two TM inputs fail; a GC needs no
  oracle input, no config input, and no trie input (assert it succeeds without
  them). Confirmed GC — unchanged behaviour under the new redeemer, still 30
  days. Confirm path — unchanged, now wrapped; a `Gc` redeemer on an
  `Unconfirmed` record accompanied by a valid oracle proof is judged by GC
  rules ONLY (it must fail if the GC conditions are absent, proving the
  dispatch cannot be smuggled).
- [ ] **Step 5:** `sbt "testOnly *"` + scalafmt + blueprint pin refresh (the
  TM hash moves; the pin-freshness test fails until refreshed).
- [ ] **Step 6: Commit** —
  `feat(tm): explicit spend redeemer and GC for Unconfirmed records`

---

### Task 2: binocular — generalize `PorSweeper` into a sweeper core + two sources

**Files:**
- Refactor: `src/main/scala/binocular/watchtower/PorSweeper.scala` (693 lines
  today — the seed for the core)
- Create: `src/main/scala/binocular/watchtower/Sweeper.scala` (core),
  `PegOutCompletionSource.scala`, `TmRecordGcSource.scala`
- Modify: `src/main/scala/binocular/cli/commands/BridgeSweepSetup.scala`,
  the watchtower wiring, `CliApp.scala` (one-shot command)
- Test: existing `PorSweeperTest` adapted, plus a source-level suite for TM GC

**Interfaces:**
- Produces: `trait SweepSource { def name: String; def candidates(ctx):
  Either[SweepError, (Seq[SweepCandidate], Seq[Skipped])] }` and
  `SweepCandidate { ref, reason, eligibleAt, build(): Either[String, Transaction] }`.
  The core `Sweeper` owns the tick, dry-run, per-item error isolation,
  in-flight suppression (`InFlightTtlMs`, keyed by `ref`), the
  halted/degraded state, persistence hooks, and reporting. Sources fail
  INDEPENDENTLY: a halted trie mirror must not stop TM GC.
  `PegOutCompletionSource` keeps every peg-out-specific behaviour that exists
  today (trie mirror, `recordConfirmed` chaining after Confirm, the
  reconstruction/catch-up path, the root cross-check). `TmRecordGcSource`
  scans the TM address, keeps records whose `creator` is the operator's
  payment key hash and whose `created + GcGraceMs` has passed, and builds one
  `TmSpendRedeemer.Gc` transaction per record.
- The refactor MUST NOT change peg-out behaviour: the existing PorSweeper
  tests are the regression net — port them, do not weaken them.

- [ ] **Step 1: Extract the core** from `PorSweeper` with peg-out logic
  moved behind `PegOutCompletionSource`, no behaviour change. Existing tests
  must pass with only mechanical adaptation; note any test you had to alter
  and why.
- [ ] **Step 2: `TmRecordGcSource`.** Eligibility as a pure function over
  `(records, walletPkh, now, chainTipRef)` → eligible / skipped-with-reason,
  unit-testable without a provider. TIP PROTECTION: never GC the `Confirmed`
  record no other record chains from (detect via the treasury linkage: the
  Confirmed record whose `btcTxid ++ 00000000` is not spent by any other
  record's embedded tx input 0); require an explicit override flag to force
  it. Transaction builder: spend with `Gc`, burn the NFT, `validFrom` past
  the deadline, creator signature, min-ADA to the wallet.
- [ ] **Step 3: Wiring.** Watchtower runs the core on its existing tick and
  after each successful Confirm (peg-out source only needs the chaining);
  config toggles per source (`bridge.sweeper.peg-outs`,
  `bridge.sweeper.tm-records`, both default on); one-shot CLI (`binocular
  sweep [--dry-run] [--source <name>] [--force-tip]`) printing a table of
  candidate, source, reason, eligible-at, action.
- [ ] **Step 4: Tests.** TM GC eligibility (both variants, deadline
  boundary, foreign creator skipped, tip protected, override honoured); core
  behaviours (in-flight suppression, per-item isolation, one source halted
  while the other proceeds — this is the key new invariant); peg-out
  regressions all still green. State plainly what is compile-only.
- [ ] **Step 5:** `sbt "testOnly *"` + scalafmt. **Commit** —
  `feat(watchtower): one sweeper for peg-out completion and TM record GC`

---

### Task 3: Documentation

**Files:** `documentation/technical_documentation.md`,
`documentation/tm-chain-migration-runbook.md` (ft repo)

- [ ] **Step 1:** The TM GC section: document the spend redeemer
  (`Confirm` | `Gc`) and add fresh check IDs continuing the [CTM-*] sequence
  for the `Unconfirmed` GC rule. Never renumber; the existing Confirmed-GC
  IDs keep their meaning and their 30-day period, now shared.
- [ ] **Step 2:** UTxO map: the `Unconfirmed` TM row changes from
  permanently locked to reclaimable by the creator after 30 days. State the
  one-period rule and the Why note in exactly one place.
- [ ] **Step 3:** TM-chain lifecycle mermaid diagram: add a GC edge from the
  `Unconfirmed` node alongside the existing Confirmed-GC edge. Single-line
  labels, no semicolons; verify it parses.
- [ ] **Step 4:** Runbook + operator docs: the unified sweeper (what each
  source does, the toggles, the tip rule and its override), and a note that
  the TM script hash changed so peg-in and trie parameters must be rebuilt
  before the migration is executed.
- [ ] **Step 5: Commit** — `docs(spec): Unconfirmed TM GC and the unified sweeper`

---

### Task 4: Submodule bump + verification

- [ ] Push binocular; bump `offchain/bitcoin-watchtower/binocular` in ft;
  full sweep (`aiken check`, `sbt "testOnly *"`, heimdall `cargo test` as an
  untouched-regression check); push ft.

---

### Settled decisions

- **One grace period (30 days) for both variants** — user directive. A
  shorter `Unconfirmed` timer would be safe (nothing third-party depends on
  such a record) but adds a second rule for dust-sized value.
- **Explicit `TmSpendRedeemer`** — user directive. Intent is declared, not
  deduced from the mint sign, and it mirrors `TmMintRedeemer`.
- **One generalized sweeper** — user directive. TM GC and peg-out completion
  are the same job; sources fail independently so a peg-out halt never blocks
  TM GC.
- **No batching.** `tmInputCount == 1` is the NFT-containment invariant.
