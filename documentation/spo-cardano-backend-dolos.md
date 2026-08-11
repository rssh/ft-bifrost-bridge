# Running the bridge off an SPO's own Cardano node

**Status:** proposal, 2026-08-11
**Audience:** SPO operators, bridge developers, auditors
**Scope:** the Cardano query backend for `heimdall` and the `binocular` watchtower. Bitcoin
infrastructure is out of scope.

## 1. Why this document exists

`heimdall` and `binocular` read Cardano through the Blockfrost REST API. Today that means the
hosted service at `blockfrost.io`.

That is a centralization problem, and it is one the spec already forbids. The infrastructure rule
in §Infrastructure assumptions is that no consensus-relevant read may depend on a centralized
query service. A hosted API operator can censor a read, serve a stale answer, or rate-limit an SPO
out of its duties. The bridge's safety arguments assume SPOs observe the chain independently.

SPOs already run a synced `cardano-node`. This document describes how to serve the bridge's
queries from that node instead.

**Conclusion up front:** one Dolos instance per SPO is sufficient. `cardano-db-sync` is not
needed. Kupo is an optional performance improvement, not a requirement.

## 2. The API surface the bridge needs

The two daemons need one Blockfrost-compatible HTTP endpoint between them. The list below was
compiled by reading the code, not the documentation.

### 2.1 heimdall

Direct HTTP through `bf_http.rs`, and the `blockfrost` crate for submission:

| Endpoint | Purpose |
|---|---|
| `GET /addresses/{address}/utxos` | live UTxOs at a bridge address |
| `GET /addresses/{address}/utxos/{unit}` | the same, filtered by asset |
| `GET /txs/{hash}` | transaction existence and block time |
| `GET /scripts/{script_hash}` | on-chain script size, for fee estimation |
| `GET /epochs/latest`, `GET /epochs/{epoch}` | epoch number and boundaries |
| `GET /epochs/latest/parameters` | protocol parameters |
| `POST /tx/submit` | submit a signed transaction |

Chain-history reads, used by completed-peg-outs trie reconstruction (`cpo_history.rs`):

| Endpoint | Purpose |
|---|---|
| `GET /addresses/{address}/transactions` | every transaction that touched a bridge address |
| `GET /txs/{hash}/utxos` | that transaction's outputs, spent or not |
| `GET /scripts/datum/{hash}/cbor` | resolve a datum hash to its preimage |
| `GET /assets/{unit}/addresses` | current holder of a singleton NFT |

### 2.2 binocular

The watchtower issues two paths itself, plus `/blocks/latest` to calibrate its slot config.
Everything else goes through the scalus `BlockfrostProvider`.

The provider's endpoint set was read out of the compiled `scalus-cardano-ledger_3` version 1.0.0
class files, which is the version `binocular` builds against:

```
/genesis                       /network            /network/eras
/blocks/latest                 /blocks/latest/txs  /blocks/slot/{slot}
/epochs/latest/parameters
/addresses/{addr}/utxos        /addresses/{addr}/transactions
/txs/{hash}                    /txs/{hash}/utxos   /txs/{hash}/redeemers   /txs/{hash}/cbor
/scripts/{hash}/json           /scripts/{hash}/cbor
/scripts/datum/{hash}          /scripts/datum/{hash}/cbor
/assets/{...}                  /accounts/{...}
POST /tx/submit
```

**The provider does NOT call `/utils/txs/evaluate`.** There are zero occurrences of `evaluate` in
its compiled strings. scalus evaluates Plutus scripts locally. No backend needs to provide script
evaluation. This matters, because Dolos does not serve that endpoint.

### 2.3 The one read that drives everything

Most of the list above is current-state: live UTxOs, latest parameters, the tip. Any backend can
answer those from the ledger state alone.

Completed-peg-outs trie reconstruction is different. It reads **outputs that no longer exist**.
`CpoHistory.scala:31` states the reason plainly: the Confirm transition spends the `Unconfirmed`
TM record that carries the data-availability hint, and completion spends the peg-out request whose
datum defines the trie entry. Both are gone from the UTxO set by the time anyone needs them, and
both stay in transaction history forever.

This single requirement is what forces archive retention. Keep it in mind for §4.

## 3. Why Dolos is enough

[Dolos](https://github.com/txpipe/dolos) is a lightweight Cardano data node by TxPipe. It keeps a
copy of the ledger and serves several APIs over it, including a Blockfrost-compatible one called
mini-Blockfrost (`minibf`).

### 3.1 Endpoint coverage is complete

Every endpoint in §2 is present in the Dolos `minibf` router. This was verified against the route
table in `crates/minibf/src/lib.rs`, not against a marketing claim of compatibility.

That includes the three that commonly go missing in Blockfrost clones:

- `POST /tx/submit`. Dolos implements it. `blockfrost-backend-ryo` does not (see §6.2).
- `GET /txs/{hash}/redeemers`.
- `GET /scripts/datum/{hash}/cbor`.

There are no gaps to work around. No second service is required to fill one in.

### 3.2 It uses the node the SPO already runs

Dolos syncs over the Ouroboros network protocol. Point `upstream.peer_address` at the operator's
own relay or block producer. The SPO's node stays the source of truth, and no third party sits in
the read path.

Dolos also exposes an Ouroboros node-to-client Unix socket of its own
(`serve.ouroboros.listen_path`), which `cardano-cli`, Ogmios, and Kupo can attach to.

### 3.3 It is maintained

Version 1.6.0 was released in July 2026. Releases are regular, and the 1.x line has had schema
versioning and pruning-correctness fixes. Bootstrapping from a Mithril snapshot brings mainnet up
in well under a day, rather than replaying from genesis.

## 4. Dolos MUST run in archive mode

Dolos has three retention shapes: ledger-only, a sliding history window, and full archive.

**Operators MUST run full archive.** Ledger-only keeps current state, which cannot answer §2.3.
A sliding window silently drops history older than the window, which corrupts reconstruction
rather than failing it loudly.

Concretely:

- Leave `sync.max_history` unset. Setting it prunes archive history to that many slots.
- Leave `storage.archive.backend` at its `redb` default. Setting it to `no_op` disables the
  archive entirely.
- Leave `storage.index.backend` at its default. `no_op` there removes the indexes that
  address-based queries need.
- `storage.state.max_history` prunes ledger state only. It does not affect archive queries.

Full archive costs more disk than ledger-only. That cost is the price of being able to
reconstruct the trie, which is a consensus-relevant operation.

## 5. Kupo is a performance improvement, not a requirement

It is easy to read heimdall's code comments and conclude Kupo is mandatory for SPOs. It is not,
and the distinction matters when you are deciding what to ask operators to install.

### 5.1 Both daemons run the same algorithm

`heimdall` and `binocular` perform the same reconstruction over the same two bridge addresses.
Neither queries less than the other.

`heimdall` implements two backends behind its `CpoHistorySource` trait: `KupoHistory` and
`BlockfrostHistory`. `binocular` implements `BlockfrostCpoHistory` and `ProviderChainHistory`, and
has no Kupo backend at all. `CpoHistory.scala:87` records that as a decision, not an omission:

> Kupo is NOT required (design rev 5.2): a watchtower, a demo box, or a non-SPO completer runs on
> Blockfrost alone.

heimdall's own comment agrees that the Blockfrost path "reconstructs the same trie with the same
checks". The difference is cost, not correctness.

### 5.2 What Kupo actually buys

For an address with *T* transactions and *D* hash-only datums:

| Backend | Requests |
|---|---|
| Kupo | 1 + *D* |
| Blockfrost-compatible | ⌈*T*/100⌉ + *T* + *D* |

Roughly one request per transaction, versus a handful.

### 5.3 Why that mattered less than it appears

heimdall gives two reasons for preferring Kupo. One is the request count above. The other is that
Kupo is self-hosted, and the spec forbids consensus-relevant reads on a centralized service.

**A self-hosted Dolos satisfies the second reason completely.** It was the whole point of the
migration.

The first reason loses most of its force too. The pain of one-request-per-transaction was the
rate limit on a hosted project. `CpoHistory.scala` says so directly: that shape is "exactly the
shape that trips a hosted Blockfrost project's rate limit". Against a Dolos on the same host there
is no rate limit and no network round trip.

Frequency also argues against extra infrastructure. heimdall's reconstruction has exactly one
production call site, `src/main.rs:4841`, and it is an operator-run CLI command that prompts for
confirmation. It is not in the daemon loop. binocular pays the cost once per process start.

### 5.4 Guidance

- SPOs SHOULD start with Dolos alone.
- Operators MAY add Kupo later if a cold-start reconstruction measures too slow against the
  history the bridge addresses actually accumulate.
- Adding Kupo to heimdall is one config line, `cardano.kupo_url`. Adding it to binocular would
  need new code.
- Operators MUST NOT run Kupo with `--prune-utxo`. A pruned Kupo cannot supply datum preimages,
  which heimdall treats as a hard error rather than a missing output.

## 6. Traps

### 6.1 Dolos mini-Kupo cannot replace Kupo

Dolos ships a `minikupo` API. It looks like a free replacement for Kupo. It is not.

`crates/minikupo/src/routes/matches.rs` hardcodes `spent_at: None` and rejects the `spent`,
`spent_after` and `spent_before` filters with "Only unspent results are available".

Reconstruction needs spent outputs (§2.3). If you ever add a Kupo backend, point it at real Kupo.
Pointing heimdall's `kupo_url` at Dolos mini-Kupo would lose exactly the data the algorithm
depends on.

### 6.2 blockfrost-backend-ryo has no transaction submission

The self-hosted Blockfrost backend has no `tx` route in its `src/routes/` tree, and maintainers
confirm submission is unimplemented. It needs `cardano-submit-api` bolted alongside, plus a proxy
to merge the two. That is on top of `cardano-db-sync` and PostgreSQL.

### 6.3 `minibf.max_scan_items` may truncate long histories

`serve.minibf.max_scan_items` caps the page scan for heavy endpoints, and defaults to `3000`.

`GET /addresses/{address}/transactions` against a long-lived bridge address is exactly such a
query. **This is unverified against a real long history, and it is the most likely thing to bite.**
Operators SHOULD raise this value, and developers SHOULD test reconstruction against an address
with more than 3000 transactions before mainnet.

### 6.4 scalus drops `scriptRef`

Unrelated to the backend choice, but adjacent. The scalus `BlockfrostProvider` does not populate
`scriptRef` on UTxOs, so the transaction builder under-estimates the Conway reference-script fee.
`binocular` works around it by keeping CIP-33 reference-script UTxOs out of input selection
(`excludeInputs` in `OracleTransactions.scala`).

Switching to Dolos neither fixes nor worsens this. Confirm that Dolos returns
`reference_script_hash` on UTxOs, because the workaround depends on recognising those UTxOs.

## 7. Setup guide

### 7.1 Prerequisites

- A synced `cardano-node`, reachable over TCP from where Dolos runs.
- Disk for a full archive, on SSD.
- The node's genesis files, or a `dolos init` run that fetches them.

### 7.2 Install

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/txpipe/dolos/releases/latest/download/dolos-installer.sh | sh
```

Homebrew (`brew install txpipe/tap/dolos`) and npm (`npm install @txpipe/dolos`) deliver the same
binary.

### 7.3 Initialise

```bash
dolos init
```

This asks a short series of questions, writes `dolos.toml`, and then bootstraps. Answer for
mainnet, and point it at your own node when it asks for an upstream peer.

### 7.4 Review the generated config

Open `dolos.toml` and confirm the keys that matter for the bridge. Start from what `dolos init`
generated rather than pasting this wholesale, because defaults change between versions.

```toml
[upstream]
# Your own relay or block producer.
peer_address = "127.0.0.1:3001"

[storage]
path = "/var/lib/dolos"

[storage.archive]
# MUST NOT be "no_op". The archive is what answers history queries.
backend = "redb"

[sync]
# max_history MUST stay unset. Setting it prunes archive history.

[serve.minibf]
listen_address = "127.0.0.1:3000"
# Default 3000 can truncate long address histories. See §6.3.
max_scan_items = 100000

# Optional. Lets cardano-cli, Ogmios or Kupo attach to Dolos.
[serve.ouroboros]
listen_path = "/var/lib/dolos/dolos.socket"
```

Bind `listen_address` to localhost, or to a private interface. The bridge daemons are the only
intended clients. mini-Blockfrost has no authentication of its own.

### 7.5 Bootstrap from a Mithril snapshot

`dolos init` triggers this automatically. To run it by hand:

```bash
dolos bootstrap mithril
```

The snapshot is signed by Cardano SPOs and verified on download. Expect several minutes to a few
hours depending on network and disk.

### 7.6 Run

```bash
dolos daemon
```

`dolos daemon` does sync and serve together. `dolos sync` and `dolos serve` split the two if you
want them in separate units.

Run it under systemd with `Restart=on-failure`, as you would any node-adjacent service.

### 7.7 Verify before wiring the bridge

```bash
# Health, and how far behind the tip.
curl -s localhost:3000/health

# Protocol parameters. Both daemons need this.
curl -s localhost:3000/epochs/latest/parameters | head -c 200

# History depth. This is the read that matters most.
curl -s "localhost:3000/addresses/<TM_ADDRESS>/transactions?count=100&page=1&order=asc" | head -c 400

# A spent output must still resolve. Pick an old bridge transaction.
curl -s localhost:3000/txs/<OLD_TX_HASH>/utxos | head -c 400
```

The last two are the archive-mode check. If either returns empty or 404 for data you know is on
chain, retention is misconfigured. Fix that before going further.

## 8. Wiring the daemons

### 8.1 heimdall: configuration only

No code change is required. `cardano.blockfrost_url` already flows through
`bf_http::base_url()`, and every `BlockfrostAPI` construction sets `settings.base_url` from the
same value, so transaction submission follows the override too.

```toml
[cardano]
network = "mainnet"
blockfrost_url = "http://127.0.0.1:3000"
blockfrost_project_id = "dolos"   # required, but not checked by Dolos
```

`network` is required whenever `blockfrost_url` is set, because the network can no longer be
inferred from the project-id prefix.

`blockfrost_project_id` stays mandatory in heimdall's config validation. Dolos ignores the value.
Any non-empty string works.

To add Kupo later:

```toml
kupo_url = "http://127.0.0.1:1442"
```

### 8.2 binocular: one small code change needed

`binocular` cannot be pointed at a local backend today. `CardanoConfig` derives the base URL from
the network alone, using `BlockfrostProvider.mainnetUrl` and its siblings. There is no
`blockfrostUrl` key.

The change is small, because both consumers already accept a base URL as a parameter:

- `BlockfrostProvider.create(projectId, baseUrl, network, slotConfig)`
- `CardanoConfig.fetchCalibratedSlotConfig(apiKey, baseUrl, defaultSlotConfig)`

Add one config key and thread it into both call sites.

**Do not route binocular through its existing `yaci` backend to reach Dolos.**
`BlockfrostProvider.localYaci(yaciStoreUrl, yaciAdminUrl)` also expects the yaci local-cluster
admin API, which Dolos does not serve.

## 9. Alternatives considered

| Option | Endpoint coverage | Footprint | Verdict |
|---|---|---|---|
| **Dolos, archive** | complete | light, single binary | **recommended** |
| Dolos + real Kupo | complete | two services | optional, for reconstruction speed |
| Yaci Store | complete per its tracker | medium, JVM | credible second source, Blockfrost layer is newer |
| db-sync + RYO | no `/tx/submit` | 64 GB RAM, 8 cores, 80k IOPS | rejected, poor fit for SPOs |
| Kupo + Ogmios only | not Blockfrost-shaped | light | rejected, needs new code in both daemons |

Yaci Store is worth keeping in view. `bf_http` is already lenient about its response quirks, such
as an omitted `tx_index`, so heimdall tolerates it today.

## 10. Open items

1. Test reconstruction end to end against a Dolos archive on preprod. This is the only item that
   exercises §2.3 for real.
2. Measure `minibf.max_scan_items` against an address with more than 3000 transactions (§6.3).
3. Confirm Dolos returns `inline_datum` and `reference_script_hash` in the Blockfrost UTxO shape.
   `bf_http::BfUtxo` reads both, and `reference_script_hash` drives coin selection.
4. Add the `blockfrostUrl` key to binocular's `CardanoConfig` (§8.2).
5. Measure full-archive disk growth on mainnet, and publish a figure SPOs can plan against.
6. Decide whether the spec's §Infrastructure assumptions should name a self-hosted
   Blockfrost-compatible API as an acceptable backend, alongside Kupo.
