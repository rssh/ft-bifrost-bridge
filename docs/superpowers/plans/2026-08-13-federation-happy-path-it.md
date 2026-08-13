# Federation Happy-Path Integration Test Implementation Plan

> **Execution note:** per this repo's CLAUDE.md, do NOT use
> `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
> Execute inline in the real clones (`~/projects/lantr/binocular`,
> `~/projects/lantr/heimdall`), task by task, committing per task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** One declarative ScalaTest suite in binocular `it/` that drives the
full Phase-1 bridge flow: bridge + oracle genesis on yaci devkit and bitcoind
regtest, Faith/Grace/Hal as a 2-of-3 FROST federation over heimdall's real HTTP
peer network, Alice's deposit swept by a TM, relayed, confirmed, and completed
into fSAT.

**Architecture:** A three-file DSL (`BridgeWorld` lifecycles, `Actors`
wrappers, `BridgeAssertions` chain-state polling verbs) under
`it/src/test/scala/binocular/federation/`. binocular commands run in-process;
heimdall runs as three spawned subprocesses; every assertion polls decoded
chain state through the existing typed readers.

**Tech Stack:** Scala 3 + ScalaTest 3.2.19, scalus-testkit `YaciDevKit` +
`Party`, os-lib subprocesses, bitcoind regtest, heimdall (Rust, cargo),
yaci-store Blockfrost-compatible API.

**Spec:** `docs/superpowers/specs/2026-08-13-federation-happy-path-it-design.md`

## Global Constraints

- Work in the REAL clones. Never commit inside `offchain/*` submodule
  checkouts; after landing, bump both gitlinks in ft-bifrost-bridge.
- binocular verification: **`sbt testFull`**, not `sbt test`. Plain `test`
  under-reports and still passes (measured: 446 vs the true 547), which is the
  stale-cache symptom binocular's CLAUDE.md describes. `testFull` gives the
  true count in ~20 s. Fall back to the full reset
  (`sbt shutdown && pkill -f sbt-launch && sbt cleanFull && sbt test`) only
  when blueprint pins or other classpath resources changed - that is the one
  thing which clears the server's open jar.
- heimdall verification: `cargo test` AND `cargo clippy --all-targets`
  (needs `nix develop`).
- Commit messages: conventional style of each repo; NEVER add a
  Claude/Anthropic co-author trailer; use "-" or "–", never "—".
- SPO names Faith/Grace/Hal and user names Alice/Bob come from
  `scalus.testing.kit.Party` (verified members).
- The suite is manual: `sbt "it/testOnly *FederationHappyPath*"`; it must
  fail fast with a one-line instruction when docker, bitcoind, or cargo is
  missing (no silent cancel).
- Oracle parameters for the suite: fork-tree depth 3, confirmation timeout 0,
  `testingMode` off (real regtest PoW headers).
- Every `expect*` verb: bounded poll, default 30 s (TM: 5 min), timeout message
  states the unfulfilled predicate; on failure dump last 50 lines of every
  actor log + decoded bridge state.

---

## Upstream facts (verified 2026-08-13, heimdall main `44a6650`)

The originally planned genesis spike is unnecessary: its questions are
answered by landed heimdall work and its docs. The executor should NOT
re-derive these:

- `heimdall demo --deterministic` runs the HTTP DKG reproducibly:
  `scripts/dkz/README.md` documents all three instances converging on a FIXED
  group key, run after run, and the run continuing Sign -> Submit with the
  LEADER posting the FROST-signed TM (proven on preprod). The `HeimdallFix`
  branch is retired and Task 5a with it.
- **No DKG rehearsal is needed at all** (heimdall `4e34da4`, PR #50).
  `frost-treasury` now reproduces the deterministic demo DKG when given no
  `--frost-key`, and prints the group key, the leaf key and the treasury
  address together. Measured 2026-08-13 against `heimdall.localdkg.toml`:

      FROST group key (x-only): b1e15a53...e53f2854
      Treasury address: tb1ptt4u8v96nqdht88dn0twemh8q88ysvjukw7cytwjc8df0cfws4jsxcxdn5

  That key is BYTE-IDENTICAL to the one `scripts/dkz/demo-spo-{1,2,3}.sh`
  document the 3-instance HTTP DKG converging on, which is the equality the
  retired spike existed to establish: the one-process derivation and the
  HTTP ceremony agree, for the same (seed, min_signers, max_signers). So
  `SpoRing.rehearseGroupKey` collapses from "spawn three processes on a mock
  chain and parse their logs" into one command invocation that also yields the
  address genesis must fund.
- The same PR fixed `frost-treasury` hardcoding `y_federation = Y_51`, which
  is true ONLY of the genesis tree. The scenario deploys with
  `y_federation = groupKey`, so the genesis default is the correct one here -
  but pass `--y-federation` explicitly, because the collapse is a property of
  this deployment, not of the command.
- The collapsed `y_federation = Y_51` convention is legal (2180e5b handles
  bridges "still using the collapsed Y_fed = Y_51 convention"); the
  "bad pair is an error" rule is the CSV ordering
  `refund_timeout > federation_csv_blocks` (`PeginTreeParams::validate`).
- WI-081: the peg-in tree has TWO leaves again (federation sweep + depositor
  refund); the depositor binary takes `--frost-key`, `--y-federation`,
  `--federation-csv-blocks`, `--refund-timeout-blocks`
  (see `scripts/put_pegin_alice.sh` – Alice/Bob depositor scripts exist).
- WI-083: heimdall's `bootstrap-treasury-info` / `bootstrap-registry` /
  `bootstrap-ban-list` are LEGACY; binocular `deploy-bridge` is the genesis
  authority (it mints all three federation NFTs in the federation tx).
- **WI-086 (heimdall `f59c621`): heimdall NEVER broadcasts to Bitcoin.** The signed TM
  travels inside the UnconfirmedTm record posted to Cardano, and the watchtower
  relays it - which is what the scenario's step 5 already assumed, now enforced.
  Consequences for the SPO TOMLs in Task 5: do NOT set `bitcoin.submit` (it is
  REFUSED now, not ignored), and `--broadcast` is gone from `treasury-self-send`
  and `federation-spend`.
- Two more devnet blockers fixed upstream while this plan was being written, both
  found by Ruslan running the WI-080 peg-in sweep against a local devnet:
  `cecf5b0` (the singleton holder lookup asked for `page=1`; Blockfrost numbers
  from 1 and yaci-store from 0, so on a devnet it read the empty second page and
  reported no singleton) and binocular `5bab3e1` (three values a short-epoch
  devnet rejects, including a one-hour `pegin-request` TTL that lands past the
  node's era-forecast horizon and fails as `TimeTranslationPastHorizon`).
  **Coordinate before writing Task 5**: `cecf5b0`'s message says it was "the last
  thing between a parsed PegInRequest and a Treasury Movement", so that half of
  this scenario already runs by hand, and the devnet TOMLs for it exist somewhere.
- **WI-070 (heimdall `64bc2f9`): nine `[cardano]` keys are DELETED and now
  REFUSED at config load**, each naming the Config field that replaced it:
  `pegin_script_address` / `pegin_policy_id` (#6), `pegout_script_address` (#7),
  `bridged_token_unit` (#2), `cpo_policy_id` (#4), `treasury_address` /
  `treasury_policy_id` (#5), `treasury_asset_name`, `treasury_info_asset_name`.
  `ConfigParams::bridge_contracts` derives all of them from one Config read; the
  network tag is the only local input left. Task 5's `HeimdallToml` MUST NOT emit
  any of these - a config carrying one does not warn, it fails to load. Preflight
  is eight steps now, not nine. Also: `heimdall demo` no longer has a fixture
  route on a live chain - it runs either against a deployed bridge (every
  identifier the Config's) or on the mock, which is exactly what this scenario
  provides.
- WI-084 ([CFG-9]): heimdall READS `params[8] = pegin_refund_timeout_blocks`
  from the Config and REFUSES a datum without it or with
  `pegin_refund_timeout_blocks <= federation_csv_blocks`. ft's `config.ak`
  and binocular's mirror do not have this field yet – hence THIS task.

---

### Task 1: params[8] – ALREADY DONE UPSTREAM (no work)

Verified 2026-08-13 after pulling all three repos. Nothing to implement:

- **ft** `6af0fc3` (PR #40, WI-084): spec [CFG-9] at
  `technical_documentation.md:867/871/2071/5274`, `config.ak` `ConfigParams`
  carries `pegin_refund_timeout_blocks`, `get_pegin_refund_timeout_blocks`
  reads index 8, `config_getters_match_datum_fields` pins it (value 28), and
  `0677f42` rebuilt `plutus.json` for the ninth params field.
- **binocular** `de243d5` (merged `e60639a`): `ConfigTypes.ConfigParams` has
  the ninth field, `deploy-bridge` writes it, `reference.conf` +
  `BridgeConfig.peginRefundTimeoutBlocks` default **720**
  (> `federation_csv_blocks` 144, so heimdall's [CFG-9] check passes), with
  `ConfigDatumEncodingTest` / `ReferenceConfTest` updated.
- **heimdall** `285687e` (WI-084): reads and enforces it.

Start execution at Task 2.

---

### Task 2: it/ scaffolding – heimdall build, process actors, ports

All in `~/projects/lantr/binocular`.

**Files:**
- Create: `it/src/test/scala/binocular/federation/HeimdallBuild.scala`
- Create: `it/src/test/scala/binocular/federation/ProcessActor.scala`
- Create: `it/src/test/scala/binocular/federation/Ports.scala`
- Test: `it/src/test/scala/binocular/federation/ScaffoldingTest.scala`

**Interfaces:**
- Produces:
  - `HeimdallBuild.binary(): os.Path` – `HEIMDALL_BIN` env override, else
    `cargo build --release` in `../../heimdall` (memoized per JVM), else
    `fail("heimdall binary unavailable: set HEIMDALL_BIN or install cargo")`.
  - `class ProcessActor(name: String, cmd: Seq[String], env: Map[String,String], logDir: os.Path)`
    with `start(): Unit`, `stop(): Unit`, `logFile: os.Path`,
    `tailLog(n: Int): String`, `awaitLogLine(pattern: Regex, timeout: FiniteDuration): String`.
  - `Ports.free(): Int` – bind-port-0 allocation.

- [ ] **Step 1: Write the failing scaffolding test**

```scala
package binocular.federation

import org.scalatest.funsuite.AnyFunSuite
import scala.concurrent.duration.*

class ScaffoldingTest extends AnyFunSuite {
  test("Ports.free returns distinct bindable ports") {
    val ps = List.fill(5)(Ports.free())
    assert(ps.distinct.size == 5)
  }
  test("ProcessActor captures output and awaits a log line") {
    val dir = os.temp.dir(prefix = "actor-test-")
    val a = ProcessActor("echo", Seq("sh", "-c", "echo hello-marker; sleep 5"), Map.empty, dir)
    a.start()
    try assert(a.awaitLogLine("hello-marker".r, 10.seconds).contains("hello-marker"))
    finally a.stop()
  }
  test("HeimdallBuild resolves a runnable binary") {
    val bin = HeimdallBuild.binary()
    val res = os.proc(bin, "--help").call(check = false)
    assert(res.exitCode == 0)
  }
}
```

- [ ] **Step 2: Run to verify it fails**

`sbt "it/testOnly *ScaffoldingTest"` – expected: compile failure (classes
missing).

- [ ] **Step 3: Implement the three objects**

`Ports.free()` binds a `ServerSocket(0)`, reads the port, closes.
`ProcessActor` uses `os.proc(cmd).spawn(stdout = logFile, stderr = logFile,
env = env)`; `awaitLogLine` polls the file every 200 ms until the regex
matches or times out, failing with the pattern and the tail.
`HeimdallBuild.binary()`: check `HEIMDALL_BIN`; else locate
`os.pwd / os.up / os.up / "heimdall"` – if wrong relative to `it/`'s
`baseDirectory`, resolve from `BINOCULAR_SIBLING_HEIMDALL` env with default
`~/projects/lantr/heimdall`; run `cargo build --release` once (memoize in a
`lazy val`), return `target/release/heimdall`.

- [ ] **Step 4: Run to verify it passes**

`sbt "it/testOnly *ScaffoldingTest"` – expected PASS (cargo build may take
minutes on first run).

- [ ] **Step 5: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): federation scaffolding - heimdall build, process actors, ports"
```

---

### Task 3: DeployedBridge – deploy-bridge returns its refs

Make genesis consumable in-process instead of scraping stdout.

**Files:**
- Modify: `src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala`
- Test: `src/test/scala/binocular/DeployBridgeResultTest.scala`

**Interfaces:**
- Produces:

```scala
case class DeployedBridge(
    configNftPolicyId: ByteString,
    completedPegInsOneShotRef: TransactionInput,
    bridgeStateOneShotRef: TransactionInput,
    federationOneShotRef: TransactionInput,
    treasuryInfoPolicyId: ByteString,
    sposRegistryPolicyId: ByteString,
    spoBansPolicyId: ByteString
)
// on DeployBridgeCommand's companion:
def deploy(config: BinocularConfig)(using ExecutionContext): Either[String, DeployedBridge]
```

`execute` delegates to `deploy` and keeps printing exactly what it prints
today (the printed lines are operator API; do not change them).

- [ ] **Step 1: Write the failing test** – a compile-level/refactor test: the
  existing `DeployBridgeCommand` tests keep passing AND a new test asserts
  `DeployedBridge` carries the refs `deploy` was built from. Because `deploy`
  needs a live provider, the unit test covers only the pure extraction:
  refactor so the tx-building steps produce a `DeployedBridge` value, and unit
  test the field mapping from known inputs (construct the case class from
  fixture refs, assert `.federationOneShotRef` etc. round-trip into the
  strings the command prints, reusing the existing print helpers).

```scala
class DeployBridgeResultTest extends AnyFunSuite {
  test("DeployedBridge prints the same ref strings the operators copy") {
    val ref = TransactionInput(TransactionHash.fromHex("ab" * 32), 3)
    val d = DeployedBridge(ByteString.fromHex("00" * 28), ref, ref, ref,
      ByteString.fromHex("11" * 28), ByteString.fromHex("22" * 28), ByteString.fromHex("33" * 28))
    assert(DeployedBridge.refString(d.federationOneShotRef) == ("ab" * 32) + "#3")
  }
}
```

- [ ] **Step 2: Run to verify it fails** – `sbt "testOnly *DeployBridgeResultTest"`.
- [ ] **Step 3: Implement** – extract `deploy` from `execute`'s body; `execute`
  pattern-matches the `Either` and prints as before. `DeployedBridge.refString`
  is the single formatter both use.
- [ ] **Step 4: Full binocular suite** – `sbt test` – expected: all green
  (previous count 544+, none newly failing).
- [ ] **Step 5: Commit (binocular)**

```bash
git add src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala src/test/scala/binocular/DeployBridgeResultTest.scala
git commit -m "refactor(cli): deploy-bridge returns a DeployedBridge for in-process callers"
```

---

### Task 4: BridgeWorld – Cardano+Bitcoin genesis, oracle, mineAndRelay

The lifecycle backbone: everything up to "bridge deployed, oracle live".

**Files:**
- Create: `it/src/test/scala/binocular/federation/BridgeWorld.scala`
- Create: `it/src/test/scala/binocular/federation/BtcChain.scala`
- Test: `it/src/test/scala/binocular/federation/GenesisSmokeTest.scala`

**Interfaces:**
- Consumes: `HeimdallBuild`, `ProcessActor`, `Ports` (Task 2);
  `DeployBridgeCommand.deploy` (Task 3); existing `YaciDevKit`,
  `RegtestBitcoindManager` (copy into `federation/` as a shared class if it is
  private to the existing suite), `InitOracleCommand`, `UpdateOracleCommand`
  logic via `CommandHelpers`.
- Produces:

```scala
final class Bridge(
    val provider: /* same provider type the existing it suites use */,
    val binocularConfig: BinocularConfig,   // fully populated post-genesis
    val deployed: DeployedBridge,
    val groupKey: ByteString,               // 32B x-only y_federation
    val btc: BtcChain,
    val logDir: os.Path
)
object BridgeWorld:
  def withBridge(groupKey: ByteString)(test: Bridge => Unit): Unit

final class BtcChain(rpc: /* bitcoind rpc client from existing manager */):
  def mine(n: Int): Unit
  def mineAndRelay(n: Int): Unit   // mine + push headers to the oracle
  def mempoolContains(txid: String): Boolean
```

`withBridge` performs, in order: start/reuse yaci container; start bitcoind;
mine 101 blocks; oracle `init` at tip (fork-tree 3, confirmation timeout 0,
testingMode off); build `BinocularConfig` programmatically (devkit URLs from
the container, bitcoind RPC, temp `state_dir`); `deploy` the bridge with
`yFederationHex = groupKey.toHex`; fund the treasury: derive the treasury
address from the group key (Task 5 wires the heimdall `frost-treasury
--frost-key` call; until then `withBridge` takes the address as a parameter
default-derived via that call), send BTC, mine, `bootstrap-bridge-state`;
`deploy-script-refs`; `register-bridge-creds`. Teardown: stop bitcoind, keep
container, delete temp dirs on success only.

**Resolved APIs** (verified against the jars, 2026-08-13 - do not re-derive):

- `YaciDevKit.container()` returns `com.bloxbean.cardano.yaci.test.YaciCardanoContainer`,
  which exposes `getYaciStoreApiUrl()` and `getLocalClusterApiUrl()` - exactly
  the two values `CardanoConfig` needs.
- binocular's commands reach the devnet through
  `CardanoConfig(network = "testnet", backend = "yaci", yaciStoreUrl = ...,
  yaciAdminUrl = ...)`; `createBlockchainProvider()` routes `"yaci"` to
  `localYaci(yaciStoreUrl, yaciAdminUrl)`. No Blockfrost project id involved.
  (heimdall, by contrast, needs the Blockfrost-compatible URL + a project id -
  see `application-devnet.conf`, which is a working example of both halves.)
- The funded devnet wallet is the standard yaci mnemonic; `WalletConfig` takes
  it directly. `scalus.testing.kit.Party` accounts are the USER wallets.
- `DeployBridgeCommand(onDeployed = collector)` (Task 3) hands back the
  `DeployedBridge` - no stdout scraping.

- [ ] **Step 1: Write the failing smoke test**

```scala
class GenesisSmokeTest extends AnyFunSuite with YaciDevKit {
  override protected def yaciConfig = YaciConfig(containerName = "binocular-yaci-devkit", reuseContainer = true)
  test("genesis brings up a readable bridge") {
    val groupKey = ByteString.fromHex("9a" * 32) // placeholder key: genesis must not care
    BridgeWorld.withBridge(groupKey) { bridge =>
      // typed Config decode via the existing reader
      val (utxo, cfg) = BridgeSweepSetup.loadConfig(/* provider, addr, policy, asset, timeout from bridge */).toOption.get
      assert(cfg.yFederation == groupKey)
      bridge.btc.mineAndRelay(3)  // oracle follows
    }
  }
}
```

- [ ] **Step 2: Run to verify it fails** – compile failure, then (after stubs)
  runtime failures walked one lifecycle stage at a time.
- [ ] **Step 3: Implement `BridgeWorld` + `BtcChain`** as above, reusing the
  existing suites' container/bitcoind/oracle code paths verbatim where they
  exist (lift `RegtestBitcoindManager` out of
  `BinocularRegtestIntegrationTest.scala` into
  `it/.../federation/RegtestBitcoind.scala` and have the old suite use the
  lifted class - do not fork the logic).
- [ ] **Step 4: Run to verify it passes** – `sbt "it/testOnly *GenesisSmokeTest"`.
- [ ] **Step 5: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): BridgeWorld genesis - devkit, regtest, oracle, bridge deploy"
```

---

### Task 5: SPO actors – TOMLs, registration, DKG, group key

**Files:**
- Create: `it/src/test/scala/binocular/federation/Spo.scala`
- Create: `it/src/test/scala/binocular/federation/HeimdallToml.scala`
- Modify: `it/src/test/scala/binocular/federation/BridgeWorld.scala`
- Test: `it/src/test/scala/binocular/federation/SpoDkgTest.scala`

**Interfaces:**
- Consumes: the **DkgRehearsal** choreography (see Upstream facts – the
  seeded HTTP DKG is reproducible, per `scripts/dkz/README.md`);
  `ProcessActor`, `HeimdallBuild`.
- Produces:

```scala
final class Spo(val name: String, val party: Party, actor: ProcessActor, val toml: os.Path):
  def expectDkgComplete(timeout: FiniteDuration = 2.minutes): Unit   // log-based, the one allowed log assertion
  def stop(): Unit
object SpoRing:
  /** Rehearse the deterministic DKG on the mock chain, return the group key. */
  def rehearseGroupKey(logDir: os.Path): ByteString
  /** Generate TOMLs, register Faith/Grace/Hal on-chain, spawn the demo processes. */
  def start(bridge: Bridge, names: List[Party]): List[Spo]
```

`HeimdallToml.render(...)` writes one TOML per SPO from a case class holding:
`demo.{base_port,min_signers=2,max_signers=3}`, `http` bind/port,
`cardano.{blockfrost_project_id,base_url,stake_source="yaci_store",mnemonic,
registry_bootstrap,treasury_info fields}` (exact key names reconciled against
`heimdall.localdkg.toml` + heimdall's WI-053 preflight output, which names
missing keys), `bitcoin.{rpc_url,rpc_user,rpc_pass,network="regtest",
fee_rate_sat_per_vb=1,federation_csv_blocks}`, `protocol` short timeouts from
the localdkg template, `protocol.state_dir` per SPO.

Registration: run `heimdall register-spo` once per SPO (subprocess, each
with its own TOML + bifrost URL), mirroring `scripts/dkz/register-spo-{1,2,3}.sh`
for the exact flag set; then assert the roster on-chain has 3 entries (read
via the registry reader used by `show-roster`, or scan the registry address
UTxOs by NFT policy from `deployed.sposRegistryPolicyId`).

Stake gotcha (from `scripts/dkz/README.md`): synthetic pools with ZERO stake
are fatal to the stake-weighted DKG roster. Set `min_stake_lovelace = 1` and
`demo_exclude_unstaked = true` in the TOMLs exactly as the dkz preprod
configs do, or delegate a trivial stake to each pool on the devnet.

- [ ] **Step 1: Write the failing test**

```scala
class SpoDkgTest extends AnyFunSuite with YaciDevKit {
  test("Faith, Grace and Hal register and finish a DKG over HTTP") {
    val groupKey = SpoRing.rehearseGroupKey(os.temp.dir(prefix = "dkg-rehearsal-"))
    BridgeWorld.withBridge(groupKey) { bridge =>
      val spos = SpoRing.start(bridge, List(Party.Faith, Party.Grace, Party.Hal))
      spos.foreach(_.expectDkgComplete())
    }
  }
}
```

- [ ] **Step 2: Run to verify it fails** – compile failure, then stage-wise.
- [ ] **Step 3: Implement** – `rehearseGroupKey` is one invocation:
  `heimdall frost-treasury --config <toml>` with no `--frost-key`, parsing
  `FROST group key (x-only): <hex>` and `Treasury address: <addr>` from its
  stdout. No processes to spawn, no mock chain, no log tailing - the key it
  prints is the one the HTTP DKG converges on (verified above). Rename it
  `SpoRing.groupKeyAndTreasury` to stop implying a ceremony that no longer
  happens. `start` renders TOMLs (real
  chain config), runs registration, spawns the three `demo --deterministic`
  processes named faith/grace/hal with logs in `bridge.logDir`.
- [ ] **Step 4: Run to verify it passes** – `sbt "it/testOnly *SpoDkgTest"`.
- [ ] **Step 5: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): SPO ring - TOML generation, on-chain registration, HTTP DKG"
```

---

### Task 6: Alice deposits – WIF, depositor binary, PegInRequest

**Files:**
- Create: `it/src/test/scala/binocular/federation/User.scala`
- Modify: `it/src/test/scala/binocular/federation/BridgeWorld.scala` (add `def user(p: Party): User`)
- Test: `it/src/test/scala/binocular/federation/DepositTest.scala`

**Interfaces:**
- Consumes: `heimdall depositor` binary (WIF-driven; every address-deciding
  value is an explicit argument), `DepositProofCommand`/`PegInRequestCommand`
  in-process, `bridge.btc`.
- Produces:

```scala
case class Deposit(outpoint: String, txid: String, vout: Int, sats: Long, wif: os.Path)
final class User(val party: Party, bridge: Bridge):
  def deposit(sats: Long): Deposit
  def completePegIn(d: Deposit): Minted     // implemented in Task 8
case class Minted(fsat: Long)
// on Bridge:
def expectPegInRequest(d: Deposit): Unit    // PIR datum decoded, amount + beacon key checked
```

`deposit(sats)`: generate a fresh regtest WIF into the temp dir (see
heimdall `scripts/gen_depositor_key.py`); fund its P2WPKH address from the
bitcoind wallet; mine 1; run the depositor exactly as
`scripts/put_pegin_alice.sh` does:

```bash
heimdall-repo/target/release/depositor \
  --config <generated toml> \
  --frost-key <groupKey hex> \
  --y-federation <Config y_federation hex> \
  --federation-csv-blocks <Config params[4..] csv> \
  --refund-timeout-blocks <Config params[8]> \
  --depositor-wif-file <wif path> \
  --deposit-amount-sat <sats> \
  --fee-sat 200 --submit
```

(under the collapsed convention `--frost-key` and `--y-federation` are the
same hex, which 2180e5b explicitly supports); mine until oracle-confirmed
(`mineAndRelay(3)`);
`deposit-proof` then `pegin-request` in-process mints the PIR with Alice's
Cardano address (from `Party.Alice.address`) as recipient.
`expectPegInRequest` polls the peg-in script address for the PIR NFT and
decodes the datum with the existing typed reader, asserting `peg_in_amount ==
d.sats` and the outpoint matches.

- [ ] **Step 1: Write the failing test**

```scala
class DepositTest extends AnyFunSuite with YaciDevKit {
  test("Alice's regtest deposit becomes a PegInRequest on the devnet") {
    val groupKey = SpoRing.rehearseGroupKey(os.temp.dir(prefix = "dkg-rehearsal-"))
    BridgeWorld.withBridge(groupKey) { bridge =>
      val alice = bridge.user(Party.Alice)
      val d = alice.deposit(100_000L)
      bridge.btc.mineAndRelay(3)
      bridge.expectPegInRequest(d)
    }
  }
}
```

- [ ] **Step 2: Run to verify it fails**, then stage-wise.
- [ ] **Step 3: Implement `User.deposit` + `expectPegInRequest`** as above.
- [ ] **Step 4: Run to verify it passes** – `sbt "it/testOnly *DepositTest"`.
- [ ] **Step 5: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): Alice's deposit path - depositor tx, proof, PegInRequest"
```

---

### Task 7: The TM leg – expectUnconfirmedTm, FROST verification

**Files:**
- Create: `it/src/test/scala/binocular/federation/TmRecord.scala`
- Create: `it/src/test/scala/binocular/federation/BridgeAssertions.scala`
- Test: extend the final suite (Task 9); intermediate verification is a manual
  run of the composed stages.

**Interfaces:**
- Consumes: running SPO ring (Task 5), a PIR on-chain (Task 6), the
  UnconfirmedTm datum reader binocular's `ConfirmTmtxCommand` path already
  uses (reuse, do not re-decode by hand), `Bip322`/schnorr verify helpers in
  `binocular.bitcoin`.
- Produces:

```scala
case class TmRecord(txid: String, rawTx: Array[Byte], sweeps: Seq[String], utxo: /* posted record */)
// on Bridge:
def expectUnconfirmedTm(within: FiniteDuration = 5.minutes): TmRecord
// in BridgeAssertions:
def frostSignedBy(groupKey: ByteString): Matcher[TmRecord]  // BIP340-verify input 0's key-path witness against the treasury output key derived from groupKey
```

`expectUnconfirmedTm` polls the TM script address (from the Config's
`tm_script_hash`) for an UnconfirmedTm record, decodes the raw BTC tx from the
datum, and extracts per-input witnesses. `frostSignedBy` recomputes the
taproot sighash of input 0 (the treasury input; prevout known from the bridge
state singleton) and BIP340-verifies the 64-byte witness signature against the
tweaked output key derived from the group key + y_federation leaf + csv - the
same derivation `frost-treasury` prints, cross-checked against the actual
prevout scriptPubKey.

- [ ] **Step 1: Unit-test the verifier on fixture data** – sign a dummy
  key-path spend with a known secret key in the test, assert `frostSignedBy`
  accepts it and rejects a flipped byte:

```scala
class FrostVerifyTest extends AnyFunSuite {
  test("frostSignedBy verifies a key-path witness and rejects a corrupted one") {
    // build a 1-in-1-out P2TR self-spend with a locally generated key,
    // taproot-sign it (bitcoin-s or the existing Bip322 helpers), wrap as TmRecord
    // assert matcher accepts; corrupt witness[0](0) ^= 1; assert matcher rejects
  }
}
```

- [ ] **Step 2: Run to verify it fails**, implement, **passes**
  (`sbt "it/testOnly *FrostVerifyTest"`).
- [ ] **Step 3: Implement `expectUnconfirmedTm`** against the reused datum
  reader; polling + failure dump per Global Constraints.
- [ ] **Step 4: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): TM record polling and FROST key-path verification"
```

---

### Task 8: Relay, confirm, complete – watchtower thread + Alice claims

**Files:**
- Create: `it/src/test/scala/binocular/federation/Watchtower.scala`
- Modify: `it/src/test/scala/binocular/federation/User.scala` (implement `completePegIn`)
- Modify: `it/src/test/scala/binocular/federation/BridgeWorld.scala` (start watchtower + proof server)

**Interfaces:**
- Consumes: `WatchtowerCommand`/`RelayCommand`/`ConfirmTmtxCommand`/
  `ServeProofsCommand`/`PegInCompleteCommand`/`SignPeginMsgCommand` internals
  in-process; `TmRecord` (Task 7).
- Produces:

```scala
final class Watchtower(thread: Thread, config: BinocularConfig):
  def expectRelayed(tm: TmRecord, timeout: FiniteDuration = 60.seconds): Unit  // bitcoind mempool poll
// on Bridge:
def confirmTm(tm: TmRecord): Unit          // runs confirm-tmtx in-process, asserts singleton spent
def state: BridgeState                     // fresh singleton read via existing typed reader
// User.completePegIn(d): sign-pegin-msg with d.wif -> pegin-complete -> Minted(fsat)
```

The watchtower runs the existing daemon loop on a daemon thread with the
suite's `BinocularConfig` (`porSweeper` on, proof server on a free port).
`confirmTm` mines nothing itself: the test mines via `mineAndRelay(3)` first,
then either observes the watchtower's own confirm or (deterministically) runs
`confirm-tmtx` in-process - implement the in-process call and ASSERT the
singleton advanced: `state.spiRoot` changed and `state.treasuryOutpoint ==
tm.txid + ":0"`. `completePegIn`: `pegin-complete --dry-run` to get the
digest, sign with Alice's WIF via the `SignPeginMsgCommand` internals,
`pegin-complete` for real; return the fSAT amount minted to
`Party.Alice.address` (query the address balance for the bridged-token unit
from the Config).

- [ ] **Step 1: Implement (no new isolated unit test; the deliverable is
  asserted by the full suite in Task 9)** - keep each verb a single protocol
  step; failure dumps per Global Constraints.
- [ ] **Step 2: Compile + spot-run** `sbt it/Test/compile` green.
- [ ] **Step 3: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): watchtower relay, TM confirm, and Alice's pegin-complete verbs"
```

---

### Task 9: The happy-path suite – full green run

**Files:**
- Create: `it/src/test/scala/binocular/federation/FederationHappyPathTest.scala`
- Delete: `GenesisSmokeTest.scala`, `SpoDkgTest.scala`, `DepositTest.scala`
  (their stages are the suite's first half; keeping them would triple the
  runtime for no added coverage - `ScaffoldingTest` and `FrostVerifyTest` stay).

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the suite exactly as the spec's target shape**

```scala
package binocular.federation

import org.scalatest.funsuite.AnyFunSuite
import org.scalatest.matchers.should.Matchers
import scalus.testing.kit.Party
import scalus.testing.yaci.{YaciConfig, YaciDevKit}
import scala.concurrent.duration.*
import BridgeAssertions.*

class FederationHappyPathTest extends AnyFunSuite with Matchers with YaciDevKit {
  override protected def yaciConfig: YaciConfig =
    YaciConfig(containerName = "binocular-yaci-devkit", reuseContainer = true)

  test("happy path: 2-of-3 federation sweeps Alice's deposit into fSAT") {
    val groupKey = SpoRing.rehearseGroupKey(os.temp.dir(prefix = "dkg-rehearsal-"))
    BridgeWorld.withBridge(groupKey) { bridge =>
      val spos @ List(faith, grace, hal) =
        SpoRing.start(bridge, List(Party.Faith, Party.Grace, Party.Hal))
      val alice = bridge.user(Party.Alice)

      val deposit = alice.deposit(100_000L)
      bridge.btc.mineAndRelay(3)
      bridge.expectPegInRequest(deposit)

      spos.foreach(_.expectDkgComplete())
      val tm = bridge.expectUnconfirmedTm(within = 5.minutes)
      tm should frostSignedBy(bridge.groupKey)
      tm.sweeps should contain(deposit.outpoint)

      bridge.watchtower.expectRelayed(tm)
      bridge.btc.mineAndRelay(3)
      bridge.confirmTm(tm)
      bridge.state.treasuryOutpoint shouldBe s"${tm.txid}:0"

      val minted = alice.completePegIn(deposit)
      minted.fsat shouldBe deposit.sats
    }
  }
}
```

- [ ] **Step 2: Run it** – `sbt "it/testOnly *FederationHappyPath*"` on a
  machine with docker + bitcoind + cargo. Iterate until green; every fix goes
  in the layer it belongs to (DSL vs binocular vs heimdall), never inline in
  the suite.
- [ ] **Step 3: Negative smoke (spec success criterion 3)** – temporarily stop
  Grace and Hal before the TM leg in a scratch copy; verify the failure names
  the step (`expectUnconfirmedTm`) and dumps actor logs. Do not commit the
  scratch; record the observed output in the commit message body.
- [ ] **Step 4: Full verification** – binocular: `sbt testFull` then the
  it suite; heimdall (if touched): `cargo test && cargo clippy --all-targets`.
- [ ] **Step 5: Commit (binocular)**

```bash
git add it/src/test/scala/binocular/federation
git commit -m "test(it): federation happy path - deposit to fSAT through a 2-of-3 FROST TM"
```

---

### Task 10: Docs + submodule bumps

**Files:**
- Modify: `~/projects/lantr/binocular/Readme.md` (short "Federation
  integration test" run section: prerequisites, env vars, the one sbt command)
- Modify: heimdall `src/main.rs` `Demo` doc comment – it still claims the demo
  is hardwired to `MockCardanoChain`; correct it to describe the
  blockfrost-driven real-chain path (this misled design work once already).
- Modify: ft-bifrost-bridge gitlinks for both submodules.

- [ ] **Step 1: Write the binocular Readme section; commit (binocular)**

```bash
git add Readme.md && git commit -m "docs: how to run the federation happy-path integration test"
```

- [ ] **Step 2: Fix the Demo doc comment; verify + commit (heimdall)**

```bash
cargo test && cargo clippy --all-targets
git add src/main.rs && git commit -m "docs: Demo drives a real chain via blockfrost, not only the mock"
```

- [ ] **Step 3: Bump both gitlinks in ft-bifrost-bridge**

```bash
cd ~/projects/lantr/ft-bifrost-bridge
git -C offchain/SPO/heimdall fetch && git -C offchain/SPO/heimdall checkout <heimdall main sha>
git -C offchain/bitcoin-watchtower/binocular fetch && git -C offchain/bitcoin-watchtower/binocular checkout <binocular main sha>
git add offchain/SPO/heimdall offchain/bitcoin-watchtower/binocular
git commit -m "chore: bump heimdall and binocular submodules to the federation-IT state"
```

---

## Self-Review

- **Spec coverage:** cast/topology (Tasks 2, 4, 5), scenario steps 1-6 (Tasks
  4, 5, 6, 7, 8, 9), genesis-key risk (resolved to DkgRehearsal by the
  Upstream-facts evidence; params[8] prerequisite is Task 1), DSL three-file shape
  (Tasks 4, 5, 6, 7, 8), failure reporting (Global Constraints + Task 9 step
  3), success criteria 1-4 (Task 9 steps 2-4), repo mechanics (Task 10). The
  spec's `BridgeAssertions.scala` exists as its own file (Task 7); lifecycle
  and actor files match the spec's names.
- **Placeholder scan:** Task 8 folds its verification into Task 9
  deliberately (integration verbs have no meaningful isolated test).
- **Type consistency:** `SpoRing.rehearseGroupKey`/`start`, `Bridge.user`,
  `Deposit`, `TmRecord`, `frostSignedBy`, `mineAndRelay` are used with the
  same signatures across Tasks 4-9.
