# bitfrost-test-scenarios

Cross-project end-to-end test harness for the Bifrost bridge: **4 heimdall SPO
instances + 1 binocular watchtower ("bitfrost") + yaci-devkit (local Cardano)
+ bitcoind (regtest)**, driven by scenario scripts. Charter: *turn the runbooks
into automated tests* — every real bridge flow spans heimdall + binocular +
the Aiken contracts + Bitcoin + Cardano, and until now all of it lived as
prose in `experiments/*.md`, executed by hand. This is the only layer where
the spec's consensus claims (deterministic TM reconstruction, byte-identical
txs across SPOs, forkless TM chain) can actually be proven.

```
                 ┌────────────┐   blockfrost-compatible API   ┌──────────────┐
  heimdall-spo1..4 ───────────►│ yaci-devkit │◄───────────────│  bitfrost    │
       │  ▲                    │  (Cardano)  │    deploys +   │ (binocular   │
       │  │ /health + DKG      └────────────┘    oracle txs   │  watchtower) │
       │  │ payloads (HTTP,                                   └──────┬───────┘
       ▼  │ pull-only)                                               │ headers
  heimdall-spoN ────────────── JSON-RPC ──────────► ┌──────────┐ ◄───┘
                                                    │ bitcoind │
                                                    │ regtest  │
                                                    └──────────┘
```

## Why bitcoind (regtest) is IN the compose, not an external node

Decision 2026-07-20. Three reasons:

1. **Scenario 3 requires it.** The federation switch spends the treasury via
   the CSV timelock leaf (`federation_csv_blocks`, default 144). On regtest
   you mine 144 blocks in one RPC call; on testnet4 you wait ~24 h of real
   time. There is no automated federation-fallback test without regtest.
2. **Both sides already support regtest.** binocular's oracle implements the
   `fPowAllowMinDifficultyBlocks` rule for testnet3/testnet4/regtest
   (`BitcoinValidator.scala`), and heimdall's `bitcoin.network = "regtest"`
   is a first-class value (`config.rs::parsed_network`).
3. **Reproducibility.** Regtest gives deterministic funding, instant
   confirmations, no faucet, no public-chain state leaking into assertions —
   the properties a CI-able suite needs.

An external running node is still supported for testnet4 smoke runs: set
`BITCOIN_RPC_URL` (+ credentials) in `.env` and start compose without the
`bitcoind` service (`docker compose up --scale bitcoind=0 ...`). The scenario
scripts read the same variables. Scenario 3 is regtest-only by nature.

## Version pinning (the risk that kills harnesses like this)

Three moving repos. Pins live in `.env` (`HEIMDALL_REF`, `BINOCULAR_REF`) and
`scripts/00-lib.sh::check_pins` warns when a source checkout's `HEAD` differs
from its pin. Contract identity is pinned by the **blueprint**: the deploy
step uses `onchain/plutus.json` from THIS repo checkout (CI enforces that the
committed blueprint reproduces from source — see
`.github/workflows/continuous-integration.yml`), so script hashes are pinned
transitively by the git ref of this repo. Do not pin hashes by hand in
scripts; they change with every compiler bump.

## Layout

- `docker-compose.yml` — the 7 services (bitcoind, yaci-devkit, bitfrost,
  heimdall-spo1..4).
- `docker/heimdall.Dockerfile`, `docker/binocular.Dockerfile` — multi-stage
  builds from sibling checkouts (paths via `.env`; binocular's in-repo
  Dockerfile is stale — no sbt in its build image, wrong jar name — so the
  working one lives here until fixed upstream).
- `config/heimdall-spo{1..4}.toml` — per-SPO configs: regtest, yaci-devkit
  blockfrost URL, container-name bifrost URLs, DKG window/health-gate tuned
  for compose (window 90 s > round2 offset 60 s + retry backoff — the
  self-healing inequality, see heimdall `EpochConfig::dkg_window`).
- `scripts/` — the scenarios:

| # | Script | Flow | Status |
|---|---|---|---|
| 1 | `01-bootstrap-dkz.sh` | Devnet up → fund wallet (faucet) → genesis treasury outpoint on regtest → 4 real stake pools (`register_pool`, 2-epoch activation + `active_stake` gate) → registry bootstrap (`bootstrap-treasury-info` → `bootstrap-registry` → `deploy-registry-ref`) → `register-spo` ×4 → `show-roster` → heimdall ×4 registry-driven DKG → assert identical `Y_51` across all 4 | **PASSING** (2026-07-20, ~80 s warm: stake-weighted 3-of-4 off the real on-chain registry, anchored ceremony window, all four SPOs converged on one `Y_51`). Automates run-dkz's "local yaci devnet / WI-024" path. Needed two heimdall fixes against yaci-store quirks: map-form cost_models and the `/epochs/latest` boundary-time fallback. |
| 2 | `02-fraud-dkz.sh` | DKG with one misbehaving/absent SPO → exclusion evidence + equivocation detection → ceremony completes 3-of-4 → (ban pipeline) | partially blocked: on-chain fault proofs are **N4** (mock verifier today); evidence + reduced-rerun assertions work now |
| 3 | `03-federation-switch.sh` | Mine past `federation_csv_blocks` → federation key spends treasury via script leaf → oracle proves the spend → key rotated to `y_federation` | Bitcoin-side spend testable now; on-chain federation-reset is **N10b** (+ witness-walker reuse **N15**) |
| 5 | `05-pegin-sweep.sh` | Derive the treasury off chain (Y_51 + y_federation) → fund it on regtest → `binocular init` + `deploy-bridge` (WI-068 genesis) → depositor builds a 35-byte `"BFR" ‖ Q_auth` deposit → `pegin-request` → `sweep-pegins`, asserting the TM **spends the deposit key-path** on Bitcoin | **PASSING** (2026-08-13, ~6 min from a clean devnet). The round trip WI-073/WI-074 deferred, and the first run of WI-068 genesis on any chain. Needs no SPO cluster: `sweep-pegins` reproduces Y_51 from the deterministic demo DKG, so what this proves is the peg-in TREE — that the beacon's Q_auth reaches the refund leaf and the taproot tweak matches. Playlog: `internal-docs/bitfrost/experiments/2026-08-13-pegin-sweep-devnet.md` |

## Devnet version and node mode: both are compatibility pins

Read this before debugging a script transaction that "just fails".

* **0.11.0-beta1** (the year-old pin this bench shipped with) is cardano-node
  10.5.0, **protocol version 10**. binocular has compiled for `vanRossemPV`
  (PV11) since 2026-07-27, so every script it deploys is rejected at submit with
  `MalformedReferenceScripts`. `.env.example` now pins **0.12.0-beta5**
  (cardano-node 11.0.1, PV11).
* **`nodeMode=companion`** (`config/yaci-node.properties`, mounted over the
  image's absent `node.properties`) is what makes that PV11 devnet able to run
  PV11 scripts. In the image's `haskell-only` fallback the devkit's own cost-model
  bootstrap NPEs and signs off with `Extended builtins may not be available` — and
  means it: the chain keeps the 251-entry PlutusV3 table, costs the extended
  builtins as `maxBound`, and every binocular transaction is rejected for
  overspending its evaluation budget. The same NPE breaks the faucet, and PlutusV2
  vanishes from the published parameters. Upstream: bloxbean/yaci-devkit#184, #185.
  Verify with
  `curl -s localhost:8080/api/v1/epochs/latest/parameters | jq '.cost_models_raw | map_values(length)'`
  — a healthy devnet reports PlutusV3 350, PlutusV2 332, PlutusV1 332.

Funding goes through the devkit's 20 pre-funded wallet accounts
(`00-lib.sh::yaci_topup`), not the faucet, which is broken on this release.

**Epoch length is load-bearing**, and scenario 5 sets its own. A transaction whose
validity ends past the node's era-forecast horizon — only half an epoch ahead — is
unsubmittable, and every oracle transaction carries a ten-minute window; but at
10800 slots the companion bootstrap's replay never finished and block production
stopped. 180 suits the DKG scenarios, 1200 suits scenario 5. The failure at either
end is `TimeTranslationPastHorizon`, which reads like a clock problem and is not.

## Usage

```bash
cp .env.example .env          # adjust source paths / pins
docker compose build
./scripts/01-bootstrap-dkz.sh
```

`keys/` and `data/` are volumes (gitignored — `keys/` holds generated demo
secrets, never commit).
