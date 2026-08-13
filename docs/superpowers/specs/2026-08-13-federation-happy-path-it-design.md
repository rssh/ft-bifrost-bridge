# Federation happy-path integration test

Date: 2026-08-13
Status: approved design
Home: `binocular` repo, `it/` sbt project (`~/projects/lantr/binocular`)

## Goal

One end-to-end ScalaTest suite, `FederationHappyPathTest`, that exercises the full
Phase-1 bridge flow against real infrastructure:

> Deploy the bridge and the Binocular oracle. Three heimdall SPOs (Faith, Grace,
> Hal) form a 2-of-3 FROST federation over their real HTTP peer network. Alice
> deposits BTC on regtest, a PegInRequest is minted on the devnet, the SPOs
> build and FROST-sign a Treasury Movement, the watchtower relays it to Bitcoin,
> the oracle confirms it, the TM is confirmed on Cardano, and Alice completes
> the peg-in and receives fSAT.

The test is declarative: one DSL verb per protocol step, assertions against
decoded chain state. The DSL is the deliverable as much as the test — peg-out,
ban, and refund scenarios MUST be expressible later without touching the
lifecycle code.

## Verified premises

These were checked against the code before this design; they are inputs, not
assumptions:

- `binocular/it/` exists: `YaciDevKit` (scalus-testkit) with a reusable
  container, a `RegtestBitcoindManager`, testcontainers 1.21.4, and every
  binocular command callable in-process.
- heimdall's `demo` command is NOT mock-only (its doc comment is stale): with
  `cardano.blockfrost_project_id` set, `run_demo` drives the epoch loop against
  a real `BlockfrostCardanoChain` — DKG over the `HttpPeerNetwork`, Update-Y,
  TM build, FROST signing rounds over HTTP, UnconfirmedTm post. The mock is a
  unit-test seam only (`src/epoch/mocks.rs`).
- `sign_phase` FROST-signs every TM input with the DKG key package; the demo
  fixture collapses `Y_fed` onto the group key, so "the federation is the
  2-of-3 FROST group" is the shape the code already supports.
- scalus-testkit's `Party` enum (Alice..Wendy) provides funded devnet
  identities with `account()`, `address()`, `signer()`.

## Scope

In scope: the single happy path above, plus the DSL and lifecycle
infrastructure it stands on.

Out of scope (follow-up scenarios on the same DSL): peg-out, bans, depositor
refund, DKG failure/cascade paths, CI wiring. The suite is manual:
`sbt "it/testOnly *FederationHappyPath*"`, budget ~10 minutes.

## Cast

| Name | Kind | Role in this scenario |
| --- | --- | --- |
| Alice | `Party.Alice` user wallet | depositor: pegs in 0.001 BTC, claims fSAT |
| Bob | `Party.Bob` user wallet | reserved for the peg-out scenario; unused here |
| Faith, Grace, Hal | heimdall subprocesses | 2-of-3 FROST federation SPOs |
| watchtower | in-process binocular | TM relay to bitcoind, proof server |

SPO names come from the same `Party` enum and label everything the test emits:
TOML files, log files, roster entries, failure dumps.

## Topology

| Process | How it runs | Purpose |
| --- | --- | --- |
| yaci devkit | testcontainers, shared reusable container (`binocular-yaci-devkit`) | Cardano devnet + yaci-store Blockfrost-compatible API |
| bitcoind | subprocess (existing `RegtestBitcoindManager`) | Bitcoin regtest chain |
| binocular | in-process Scala calls | oracle init/update, bridge genesis, script refs, creds, PegInRequest, TM relay, confirm-tmtx, proof server, pegin-complete |
| heimdall ×3 | subprocesses | `heimdall demo` epoch loop per SPO |

Oracle parameters: 3-block forktree, 0 confirmation timeout, `testingMode`
off — real regtest PoW headers, as `BinocularRegtestIntegrationTest` already
does.

heimdall binary: built once per JVM with `cargo build --release` in the sibling
checkout; `HEIMDALL_BIN` overrides and skips the build. Missing cargo or
bitcoind fails the suite immediately with a one-line instruction — no silent
`assume`-cancel.

Per-SPO TOML (generated into a temp dir): shared `demo.min_signers = 2`,
`demo.max_signers = 3`, the shared demo seed; per-SPO `bifrost_url` on a free
port and bifrost identity; `cardano.blockfrost_project_id` + base URL pointing
at yaci-store; `cardano.stake_source = "yaci_store"`; bitcoind regtest RPC.

## Scenario timeline

Each numbered step is one or two DSL verbs in the test body.

1. **Genesis.** Derive the 2-of-3 group key with the deterministic demo DKG
   (same seed the SPOs use) → `deploy-bridge` with `y_federation = group key`
   → fund the Bitcoin treasury at the derived Taproot address (self-send
   normalization if needed) → `bootstrap-bridge-state` → `deploy-script-refs`
   → `register-bridge-creds` → register Faith, Grace, Hal on-chain with their
   `bifrost_url`s.
2. **Oracle.** `init` at the regtest tip; a `mineAndRelay(n)` verb mines n
   blocks and feeds the headers to the oracle in one motion.
3. **Deposit.** Alice sends 0.001 BTC to the peg-in address; mine until the
   oracle confirms the block; `deposit-proof` → `pegin-request` mints the
   PegInRequest on the devnet with Alice as recipient.
4. **TM.** Faith, Grace, Hal's epoch loops pick up the PIR: DKG over HTTP →
   Update-Y → TM build → FROST 2-of-3 signing rounds → UnconfirmedTm posted.
   The test asserts the TM sweeps Alice's outpoint and its input signatures
   verify under the group key.
5. **Relay + confirm.** The watchtower relays the signed TM to bitcoind (assert
   mempool presence); `mineAndRelay(3)`; the oracle confirms the TM block;
   `confirm-tmtx` spends the bridge-state singleton — assert `spi_root`
   advanced and the treasury head equals the TM's output 0.
6. **Complete.** The proof server serves the SPI membership proof;
   `pegin-complete` burns the PIR NFT and mints fSAT — assert Alice's wallet
   holds exactly the deposited satoshis in fSAT.

### Genesis key risk (known, contained)

If the HTTP DKG's group key does not reproduce the deterministic demo key (rng
wiring), genesis switches to: run the DKG ceremony first, read the group key,
then deploy the bridge with it. This choice lives entirely inside
`BridgeWorld.genesis()`; no other component or test line moves.

## DSL

Three files in `it/src/test/scala/binocular/federation/`:

- **`BridgeWorld.scala`** — lifecycles and genesis. Owns the container,
  bitcoind, heimdall build + spawn, TOML generation, port allocation, temp
  dirs, log capture, teardown. Exposes `withBridge { bridge => ... }`.
- **`Actors.scala`** — `Spo`, `User`, `Watchtower` wrappers. An `Spo` is a
  running process + its config + its log stream. A `User` wraps a `Party` and
  the deposit/claim commands.
- **`BridgeAssertions.scala`** — the `expect*` verbs. Every assertion polls
  decoded chain state through the existing typed readers (`ConfigDatum`,
  `BridgeState`, PIR datum, bitcoind RPC) — never logs. Single exception:
  DKG-phase progress, observable only in SPO logs.

Target shape of the test body:

```scala
test("happy path: 2-of-3 federation sweeps Alice's deposit into fSAT") {
  world.withBridge { bridge =>
    val List(faith, grace, hal) = bridge.spos        // running, roster on-chain
    val alice = bridge.user(Party.Alice)

    val deposit = alice.deposit(0.001.btc)
    bridge.btc.mineAndRelay(3)
    bridge.expectPegInRequest(deposit)               // PIR datum decoded + checked

    val tm = bridge.expectUnconfirmedTm(within = 5.minutes)
    tm.signature shouldBe frostSignedBy(bridge.groupKey)
    tm.sweeps should contain(deposit.outpoint)

    bridge.watchtower.expectRelayed(tm)              // visible in bitcoind mempool
    bridge.btc.mineAndRelay(3)
    bridge.confirmTm(tm)                             // singleton spent

    bridge.state.spiRoot should not be emptyRoot
    bridge.state.treasuryOutpoint shouldBe tm.txid.outpoint(0)

    val minted = alice.completePegIn(deposit)
    minted.fsat shouldBe deposit.sats
  }
}
```

The DSL layer MUST NOT contain scenario logic (no "and then confirm"): verbs
are single protocol steps, so failure output points at the exact step and
future scenarios can reorder them.

## Failure reporting and flakiness

- Every `expect*` verb is a bounded poll: default 30 s; TM production 5 min.
  The timeout message states the predicate that never became true.
- Each actor's stdout/stderr streams to `it/target/federation-logs/<name>.log`.
  On any failure the DSL dumps the last 50 lines of every actor's log plus the
  decoded bridge state. With five processes in play, this dump is what makes
  the suite debuggable rather than abandoned.
- Ports are allocated from ephemeral range at startup, never hardcoded.
- `afterAll`: kill heimdall processes, stop bitcoind, keep the yaci container
  (reuse), delete temp dirs only on success.

## Repo mechanics

- Test + DSL land in `~/projects/lantr/binocular` (real clone; never commit in
  the ft submodule checkout).
- heimdall changes only if the test flushes out real defects. Expected
  candidates found during design: the stale "hardwired to MockCardanoChain"
  doc comment on `Demo`; possible config polish around the demo/registry path.
  Those land in `~/projects/lantr/heimdall`.
- After landing, update both gitlinks in ft-bifrost-bridge (they are already
  stale and due for a bump).

## Success criteria

1. `sbt "it/testOnly *FederationHappyPath*"` passes on a dev machine with
   docker, bitcoind, and cargo available, in ~10 minutes.
2. The test body reads as the scenario: every protocol step is one DSL verb;
   no process management, ports, or paths appear in it.
3. A deliberately broken step (e.g. stopping Hal AND Grace before the TM)
   produces a failure that names the step and dumps actor logs.
4. binocular and heimdall suites stay green (`sbt test` after full cache
   reset; `cargo test` + `cargo clippy --all-targets`).
