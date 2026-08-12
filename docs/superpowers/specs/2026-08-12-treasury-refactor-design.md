# Treasury Refactor: One-Shot Identity, Constant NFT Name, Config-Held Federation

Date: 2026-08-12, rev 5.5. Status: proposed, pending approval.

This revision rebuilds `treasury.ak` and fixes the way `spos-registry.ak` finds
the Treasury state UTxO. It makes seven changes:

1. `treasury_info` is parameterized by a one-shot outpoint, so its NFT is a
   singleton by construction.
2. The Treasury state NFT asset name becomes the constant `"BFRTRY"`.
3. The mint redeemer is deleted, and the bootstrap datum is verified instead.
4. A `Retire` branch lets the Treasury state UTxO be spent and its NFT burned.
   It is gated on the Config NFT burn, and `config.ak`'s own `Retire` is gated on
   this one ([CFG-8]) — mutually, so neither can be retired alone.
5. `last_reset_tm_txid` is deleted, and `y_federation` and
   `federation_csv_blocks` move to the Config datum.
6. `spos-registry.ak` authenticates the Treasury state UTxO by NFT, which it
   does not do today.
7. The Config NFT asset name becomes the constant `"BIFCFG"`, and no validator
   takes it as a parameter any more.

**This design assumes a FRESH DEPLOYMENT.** Nothing on preprod is preserved.
The Config datum is re-indexed and every validator gets a new hash, including
`bridged-token.ak`, so fSAT is minted under a new policy id. Tokens held under
the old policy are not carried forward.

> **Implementation status.** IMPLEMENTED on-chain, and reviewed. Two rules were
> added during review and are not described below: [CFG-8] makes the Config and
> Treasury retirements mutually required, and [TSY-23]/[TSY-24] stop the
> registry's `Bootstrap` mint from satisfying [TSY-13]. Both are in
> `documentation/technical_documentation.md`, which is authoritative. The
> heimdall builders follow in their own repository.

## Definitions and Abbreviations

Terms already defined in `documentation/technical_documentation.md` keep their
meaning. This revision adds none. The terms used most here:

| Term | Meaning |
|---|---|
| **Treasury state UTxO** | The NFT-authenticated singleton at `treasury.ak`. It holds the Bifrost identity root and the current treasury group key. |
| **Treasury state NFT** | The token that authenticates that UTxO. Asset name `"BFRTRY"` after this revision. |
| **Config UTxO** | The NFT-authenticated singleton at `config.ak` holding `ConfigDatum`. |
| **the pin** | The check that a UTxO presented as the Treasury state UTxO really is it. |
| **one-shot outpoint** | An outpoint consumed by the bootstrap transaction. Baking it into a policy makes that policy mintable once. |
| **MPF** | Merkle Patricia Forestry. |

## Problem

Three defects share one root cause: the Treasury state UTxO has no enforceable
identity.

### P1. The registry does not authenticate the Treasury state UTxO

`spos-registry.ak` locates the Treasury state UTxO by redeemer index alone:

```aiken
// validators/bitcoin/spos-registry.ak:116-117
let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
let treasury_output = utils.safe_list_at(self.outputs, treasury_output_index)
```

`get_treasury_datum` then requires only an inline datum of the right shape. No
NFT check and no address check exist on either side.

A registrant exploits this in four steps:

1. Add a plain wallet UTxO carrying a `TreasuryDatum` datum with a chosen
   `bifrost_identity_root`.
2. Point `treasury_input_index` and `treasury_output_index` at it and at its
   change output.
3. The [REG-5] absence proof now runs against a trie the registrant chose, so it
   always passes.
4. The registry list gains a real membership token, and the real Treasury state
   UTxO is never spent.

The result breaks the global uniqueness of `bifrost_id_pk` that [REG-5] and
[DRG-4] exist to enforce. The identity root also desynchronizes from the
registry list. The same hole exists on the `Deregister` path.

> **Why the obvious fix does not work today.** `treasury_info` takes
> `registry_policy_id` as a parameter, so the treasury policy id is a function
> of the registry policy id. `spo_registry` therefore cannot take
> `treasury_policy_id` as a parameter. The dependency is a cycle, and the pin
> cannot be a compile parameter until the cycle is broken.

### P2. The Treasury state NFT is not a singleton

`treasury.ak`'s mint branch is one-shot per outpoint, not one-shot per bridge.
Anyone MAY consume any outpoint they own and mint a distinct Treasury state NFT
whose datum they choose.

The tokens are not fungible. The asset name is
`sha256(serialiseData(input_ref))`, and an outpoint is consumable once, so two
mints can never share an asset name. The defect is impersonation, not
fungibility: rival Treasury state UTxOs can exist, and only an asset-name pin
distinguishes the real one.

Two spec statements are currently false:

* §Treasury state UTxO says the NFT is "minted exactly once by the protocol
  bootstrap (K1)".
* §Parameter registry says the Treasury state NFT identity is a **validator
  parameter**. No validator takes it.

### P3. The datum holds a dead field and two misplaced fields

* `last_reset_tm_txid` is inert. Its only writer, the `FederationReset` branch,
  is withdrawn ([UY-7], [UY-8]).
* `y_federation` and `federation_csv_blocks` are instance configuration, not
  state. No branch rotates them. §Treasury state UTxO's field-permission matrix
  promises a "Federation-key rotation (rare; an Update-Y variant)", and no such
  branch exists.

## Design

### D1. Treasury identity

`treasury.ak` MUST declare:

```aiken
validator treasury_info(tx0: ByteArray, index0: Int, config_policy_id: PolicyId)
```

`lib/bifrost/constants.ak` MUST define `treasury_info_nft_asset_name` as
`"BFRTRY"`. It currently holds the stale value `""`.

* **[PRE-1]** REVISED. `treasury.ak` MUST NOT take `tm_nft_policy_id`. It MUST
  NOT take `registry_policy_id` either. The original rationale stands: a
  compile parameter naming another bridge script breaks permanently on that
  script's redeploy, and this script's state UTxO can never move.
* **[PRE-3]** NEW. `treasury.ak` MUST take the Config NFT policy id as a
  parameter. The Config identity is chosen at bootstrap and never changes, so
  it is the one identity safe to bake in.
* **[PRE-4]** NEW. `treasury.ak` MUST read `spos_registry_policy_id` from the
  Config datum, not from a parameter.

> **Why the Config identity is safe to bake in but the registry's is not.** The
> Config UTxO is the root of the identity graph. Its policy id depends only on
> its own one-shot outpoint, and after [CFG-7] its asset name is a constant.
> Every other identity in the bridge is published inside its datum and is
> therefore replaceable by governance.

### D2. The dependency cycle breaks

Deployment order becomes a chain with no cycle:

```
choose Config one-shot outpoint          (name is the "BIFCFG" constant)
        |
        v
  config policy id  ------> treasury_info(tx0, index0, config_policy_id)
                                    |
                                    v
                            treasury policy id ---> spo_registry(btx, bidx, treasury_policy_id)
                                                            |
                                                            v
                                                   registry policy id
                                                            |
                            (both ids are written into the Config datum at the bootstrap mint)
```

The Config *identity* is fixed before any script is built. The Config *datum* is
written at the bootstrap mint, by which time every script hash is known.

### D3. TreasuryDatum

```aiken
pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  current_spos_frost_key: ByteArray,
}
```

* **[TSY-1]** NEW. `TreasuryDatum` MUST have exactly two fields. A reader MUST
  decode it as `TreasuryDatum` and access fields by name, per [LIB-1].

> **Why a typed decode and a fixed arity.** The Config datum alone must stay
> append-extensible, because every contract is parameterized by the Config NFT
> and so the Config alone cannot be swapped. The Treasury state UTxO sits behind
> its own NFT, and replacing it is a bootstrap, so its datum gains nothing from
> extensibility.

### D4. Redeemers

`TreasuryMintRedeemer` MUST be deleted. The mint handler MUST accept `Data` and
ignore it.

```aiken
pub type TreasurySpendRedeemer {
  RegistryUpdate { config_ref_input_index: Int }
  UpdateY { epoch: Int, signature: ByteArray, config_ref_input_index: Int }
  Retire
}
```

> **Revised during implementation.** This block first declared
> `RegistryUpdate { new_bifrost_identity_root, config_ref_input_index }` and
> `UpdateY { new_spos_frost_key, epoch, signature, config_ref_input_index }`.
> Neither named value survived: the continuing output's datum is the only source
> of truth for both, so a redeemer copy could only restate it.
> `new_bifrost_identity_root` was never constrained by `treasury.ak` at all —
> `spos-registry.ak` owns that value through the [REG-5] MPF proof — and reading
> `new_spos_frost_key` from the datum is safe because `rotation_sig_msg` commits
> to it, so changing the datum's key invalidates the signature. Each field was
> also 32 bytes of witness paid for on every update, and one more pair of values
> that had to agree.

* **[TSY-2]** NEW. `treasury.ak` MUST locate the Config reference input by the
  redeemer's `config_ref_input_index`. It MUST NOT scan `reference_inputs` for
  the Config NFT.

> **Why an index and not a scan.** A scan costs O(reference_inputs), and a scan
> that finds nothing silently picks a wrong UTxO instead of failing. `peg-in.ak`
> already states this rule for the bridge state singleton.

`Retire` carries no index. It checks a burn by the parameterized Config policy
id and the `"BIFCFG"` constant, so it needs no Config datum read.

`rotation_sig_msg` is unchanged. The signed message stays
`sha2_256(tag ++ txid ++ vout LE(4) ++ epoch BE(8) ++ new_key)`, so the existing
BIP340 test vectors remain valid.

### D5. Config datum

`ConfigDatum` MUST be re-indexed. Identities and keys stay at the top level.
Tunable numbers move into `params`.

| # | Field | On-chain reader |
|---|---|---|
| 0 | `update_auth` | `config.ak` |
| 1 | `params` | none (nested record) |
| 2 | `bridged_token_policy` | `peg-in.ak`, `peg-out.ak`, `bridged-token.ak` |
| 3 | `completed_peg_ins_policy` | `peg-in.ak` |
| 4 | `bridge_state_policy` | `peg-in.ak`, `peg-out.ak` |
| 5 | `tm_script_hash` | none, per [CFG-2] |
| 6 | `peg_in_script_hash` | `completed-peg-ins-merkle-tree.ak`, `bridged-token.ak` |
| 7 | `peg_out_script_hash` | `bridged-token.ak` |
| 8 | `spo_bans_policy_id` | none |
| 9 | `spos_registry_policy_id` | `treasury.ak` (NEW reader) |
| 10 | `treasury_info_policy_id` | none |
| 11 | `y_federation` | `treasury.ak` (NEW reader) |

`ConfigParams`:

| # | Field |
|---|---|
| 0 | `schedule` (nested record) |
| 1 | `fee_rate_sat_per_vb` |
| 2 | `per_pegout_fee` |
| 3 | `min_peg_out_fbtc` |
| 4 | `base_ban_duration_ms` |
| 5 | `max_faults_before_permanent` |
| 6 | `max_validity_window_ms` |
| 7 | `federation_csv_blocks` |

* **[CFG-4]** NEW. `treasury_info_asset_name` is WITHDRAWN as a Config field.
  The name is the `"BFRTRY"` constant.
* **[CFG-5]** NEW. A new Config field MUST be appended at the tail. A field MUST
  NOT be inserted. `params` sits at index 1 and MUST NOT move.
* **[CFG-6]** NEW. An identity or a key MUST be a top-level field. A tunable
  number MUST live inside `params`.
* **[CFG-7]** NEW. The Config NFT asset name is the protocol constant
  `"BIFCFG"`, defined in `lib/bifrost/constants.ak`. No validator MAY take it
  as a parameter. `config.ak`, `peg-in.ak`, `peg-out.ak`, `bridged-token.ak`
  and `completed-peg-ins-merkle-tree.ak` MUST drop the parameter and read the
  constant.

> **Why the name must be a constant everywhere, not just in `treasury.ak`.** A
> constant in one script and a parameter in five others is a divergence waiting
> to happen. If a deployment passes any other name, `treasury.ak` looks for a
> token that does not exist. Every branch then fails, including `Retire`, whose
> Config-burn check names the same constant. The Treasury state UTxO would be
> unspendable forever, with no recovery path. One definition removes the class.

> **Why a constant name does not prevent two instances.** The Config policy id
> is the hash of `config.ak` applied to its own one-shot outpoint, so two
> instances on one network still have distinct Config NFTs. The name was never
> what separated them. This follows the same conversion [CFG-1] made for
> `"fSAT"`, and the `fsat-config-tx-migration.md` deployment made for `"CPI"`
> and `"CPO"`.

> **Why `params` moves to index 1.** Under the append rule every index is
> frozen, so `params` at the tail never moves either. The problem is the
> instruction, not the index: the current comment opens with "`params` comes
> LAST, and deliberately" and then says appends go after it. An editor who reads
> the first clause and stops will insert before `params` to keep it last, and
> shift every field after it. At index 1 there is no "last" property left to
> preserve.

> **Why `y_federation` and `federation_csv_blocks` split.** [CFG-6] decides it.
> `y_federation` is a key, so it is top level, and `treasury.ak` reads it.
> `federation_csv_blocks` is a timeout count, so it is a tunable. An off-chain
> reader deriving a Taproot address takes field 11 and `params` field 7.

### D6. Federation-key rotation becomes real

Moving `y_federation` and `federation_csv_blocks` into the Config datum makes
them governance data. A Config `Update` rotates them. That is the
federation-key rotation the field-permission matrix promises and no branch
implements.

* **[FED-4]** NEW. Before a federation-key rotation takes effect, the roster
  MUST sweep or refund every in-flight peg-in against the old addresses. This
  gives an ID to the existing unnumbered rule in §Treasury state UTxO; only the
  writer changes.

## Checks

### Treasury bootstrap (the mint, positive branch)

* **[TSY-3]** NEW. `treasury.ak` MUST verify that the transaction spends
  `OutputReference(tx0, index0)`.
* **[TSY-4]** NEW. `treasury.ak` MUST verify that the transaction mints exactly
  one token under its own policy, and that its asset name is `"BFRTRY"`.
* **[TSY-5]** NEW. `treasury.ak` MUST verify that exactly one output sits at its
  own script credential, and that this output has no stake credential.
* **[TSY-6]** NEW. `treasury.ak` MUST verify that this output holds the Treasury
  state NFT and no other non-ADA asset.
* **[TSY-7]** NEW. `treasury.ak` MUST verify that this output's inline datum
  decodes as `TreasuryDatum`.
* **[TSY-8]** NEW. `treasury.ak` MUST verify that both datum fields are 32
  bytes long.
* **[PRE-2]** NEW. The deployer MAY seed any `bifrost_identity_root`, including
  a non-empty one. The previous rule pinning `mpf.root(mpf.empty)` is
  WITHDRAWN. The ID is stated in the spec for the first time here; heimdall's
  DecisionsLog already cites it for the off-chain half.

> **Why the bootstrap values are free.** The policy id contains the one-shot
> outpoint, so only the deployer can ever mint. At mint time the deployer is the
> instance creator, not an adversary, and a value check is a self-check. [PRE-2]
> is what lets a replacement deployment carry a registered roster forward
> instead of re-registering every SPO. heimdall already implements the flag and
> warns that the on-chain half is missing.

### Treasury burn (the mint, negative branch)

* **[TSY-9]** NEW. `treasury.ak` MUST verify that the transaction burns exactly
  one token under its own policy, and that its asset name is `"BFRTRY"`.
* **[TSY-10]** NEW. `treasury.ak` MUST NOT check authorization in the mint
  handler.

> **Why no authorization on the burn.** The Treasury state NFT only ever sits at
> the `treasury.ak` address, because every spend branch that keeps it forces a
> continuing output. Burning it therefore requires spending the Treasury state
> UTxO, which runs the `Retire` branch. `config.ak` makes the same argument for
> its own burn.

### Treasury spend, all branches

* **[TSY-11]** NEW. `treasury.ak` MUST verify that its own input holds exactly
  one Treasury state NFT.

### Treasury spend, `RegistryUpdate`

* **[TSY-12]** NEW. `treasury.ak` MUST read `spos_registry_policy_id` from the
  Config reference input, authenticated by the parameterized Config NFT.
* **[TSY-13]** NEW. `treasury.ak` MUST verify that the summed mint quantity
  under `spos_registry_policy_id` is not zero.

> **Why a sum and not a count.** `Register` mints one membership token and
> `Deregister` burns one, so a sum distinguishes them from an untouched
> registry. A transaction that mints one token and burns another under the same
> policy sums to zero and is rejected. That is the existing behaviour, and no
> registry redeemer builds such a transaction.
* **[TSY-14]** NEW. `treasury.ak` MUST verify that exactly one output sits at
  its own script credential, and that this output's address and value equal the
  spent input's.
* **[TSY-15]** NEW. `treasury.ak` MUST verify that the continuing datum equals
  the spent datum with only `bifrost_identity_root` replaced.

### Treasury spend, `UpdateY`

* **[UY-5]** REVISED. `treasury.ak` MUST read `y_federation` from the Config
  reference input, not from its own datum. The rest of [UY-5] is unchanged: the
  federation's BIP340 signature is a standing co-authority for the rotation.
* **[UY-6]** stays WITHDRAWN. The federation MAY name any key.
* **[UY-7]**, **[UY-8]** stay WITHDRAWN.
* **[TSY-16]** NEW. `treasury.ak` MUST verify that `new_spos_frost_key` is 32
  bytes long.
* **[TSY-17]** NEW. `treasury.ak` MUST verify that the continuing datum equals
  the spent datum with only `current_spos_frost_key` replaced.
* **[TSY-18]** NEW. `treasury.ak` MUST verify a BIP340 signature over
  `rotation_sig_msg` under the spent datum's `current_spos_frost_key`, or under
  the Config's `y_federation`.

[TSY-14] applies to this branch too.

### Treasury spend, `Retire`

* **[TSY-19]** NEW. `treasury.ak` MUST verify that the transaction burns exactly
  one Config NFT, identified by the parameterized policy id and the `"BIFCFG"`
  constant.
* **[TSY-20]** NEW. `treasury.ak` MUST verify that the transaction burns exactly
  one Treasury state NFT.
* **[TSY-21]** NEW. `treasury.ak` MUST NOT require a continuing output on this
  branch.
* **[TSY-22]** NEW. `treasury.ak` MUST NOT check any signature on this branch.

> **Why the Config burn is sufficient authorization.** The Config NFT only ever
> sits at the `config.ak` address. Burning it requires spending the Config UTxO,
> which runs `config.ak`'s `Retire` branch under `update_auth`. Governance
> authorization is therefore inherited, and duplicating it here would add a
> second thing to keep in sync.

### SPO registry: the pin

`spo_registry` MUST declare:

```aiken
validator spo_registry(
  bootstrap_tx_id: ByteArray,
  bootstrap_output_index: Int,
  treasury_policy_id: PolicyId,
)
```

* **[REG-6]** NEW. `spos-registry.ak` MUST verify that the treasury input holds
  exactly one token named `"BFRTRY"` under `treasury_policy_id`.
* **[REG-7]** NEW. `spos-registry.ak` MUST verify that the treasury output holds
  exactly one such token.
* **[REG-8]** NEW. `spos-registry.ak` MUST verify that the treasury output's
  address equals the treasury input's address.
* **[DRG-5]** NEW. [REG-6], [REG-7] and [REG-8] apply unchanged to
  `Deregister`.
* **[REG-5]** and **[DRG-4]** are unchanged in wording. They become enforceable
  against the real Treasury state UTxO for the first time.

## Trust model change

Governance gains an indirect path to the treasury group key. It rewrites
`y_federation` through a Config `Update`, then signs an Update-Y under the key
it just installed.

This widens no boundary. `update_auth` can already rewrite `bridged_token_policy`
and every script hash a reader resolves, so it can already halt or redirect the
bridge. The path is recorded here because it is new in form, not in power.

The bound is unchanged and stated in §Trust model: all bridge authority sits at
the host chain's trust floor.

## Consumers that move

| Consumer | Change |
|---|---|
| `validators/bitcoin/treasury.ak` | Rewritten. New parameters, new branches, new tests. |
| `validators/bitcoin/spos-registry.ak` | New `treasury_policy_id` parameter. [REG-6] to [REG-8] and [DRG-5]. |
| `lib/bifrost/types/treasury.ak` | `TreasuryDatum` drops to two fields. `TreasuryMintRedeemer` deleted. `Retire` added. |
| `lib/bifrost/types/config.ak` | Re-indexed record, re-indexed getters, `get_y_federation` and `get_federation_csv_blocks` added, `get_treasury_info_asset_name` deleted. |
| `lib/bifrost/constants.ak` | `treasury_info_nft_asset_name` becomes `"BFRTRY"`. `config_nft_asset_name` added as `"BIFCFG"`. |
| `validators/bitcoin/config.ak` | Drops the `config_asset_name` parameter per [CFG-7]. Test fixture `t_datum_data` rebuilt for the new layout. |
| `peg-in.ak`, `peg-out.ak`, `bridged-token.ak`, `completed-peg-ins-merkle-tree.ak` | Each drops its config-NFT asset-name parameter per [CFG-7]. Otherwise only the index-map comments change. All four get a new hash, because the getters they call moved. |

The index-map comments at `config.ak:163`, `peg-out.ak:242` and
`bridged-token.ak:89` MUST be updated.

## Off-chain: heimdall

The real clone is `~/projects/lantr/heimdall`. Work happens there, never in the
submodule checkout.

| File | Change |
|---|---|
| `src/cardano/treasury_datum.rs` | Two-field datum. Encode and decode drop three fields. |
| `src/cardano/treasury_bootstrap.rs` | No mint redeemer. New script parameters. Free identity root. |
| `src/cardano/treasury_info.rs` | Locate the UTxO by the `"BFRTRY"` constant, not a Config field. |
| `src/cardano/update_y.rs` | Read `y_federation` from the Config datum. Add `config_ref_input_index` to the redeemer. |
| `src/cardano/register_spo.rs` | Unchanged logic. The treasury input it already builds must now satisfy [REG-6] to [REG-8]. |
| `src/cardano/blueprint.rs` | New parameter lists for `treasury_info` and `spos_registry`. The config-NFT asset-name argument is dropped from `config`, `peg_in`, `peg_out`, `bridged_token` and `completed_peg_ins_merkle_tree` per [CFG-7]. |
| `src/cardano/config_params.rs` | New Config field indexes. |
| `src/cardano/roster.rs`, `src/bitcoin/taproot.rs`, `src/epoch/*` | Take `y_federation` and `federation_csv_blocks` from the Config datum. |
| `src/main.rs:2578` | Delete the [PRE-2] warning. The on-chain change ships here. |
| `src/config.rs` | Field comment referencing the treasury-held identity root. |

## Off-chain: binocular

No change. Neither `y_federation` nor `federation_csv_blocks` appears in the
binocular tree, and `TreasuryMovementValidator` does not read `TreasuryDatum`.

## Test plan

Aiken tests, in `treasury.ak` unless noted.

**Mint, positive**

1. Happy path.
2. Rejects a missing one-shot input.
3. Rejects a wrong asset name.
4. Rejects a quantity other than 1.
5. Rejects an extra non-ADA asset in the output.
6. Rejects two outputs at the script credential.
7. Rejects a datum that does not decode as `TreasuryDatum`.
8. Rejects a field that is not 32 bytes.
9. Accepts a non-empty `bifrost_identity_root`, which pins [PRE-2].

**Mint, negative**

10. Accepts a burn of exactly one `"BFRTRY"`.
11. Rejects a mixed mint and burn.

**Spend, `RegistryUpdate`**

12. Happy path.
13. Rejects a change to `current_spos_frost_key`.
14. Rejects a transaction with no registry mint or burn.
15. Rejects a reference input that does not carry the Config NFT.

**Spend, `UpdateY`**

16. Happy path, signed by the outgoing key.
17. Happy path, signed by the federation under the Config's `y_federation`,
    which pins the revised [UY-5].
18. Rejects a wrong epoch.
19. Rejects a wrong signer.
20. Rejects a change to `bifrost_identity_root`.
21. Rejects a reference input that does not carry the Config NFT.

**Spend, `Retire`**

22. Happy path: both NFTs burned.
23. Rejects a transaction that does not burn the Config NFT.
24. Rejects a transaction that does not burn the Treasury state NFT.

**`spos-registry.ak`**

25. `Register` rejects a treasury input that does not carry the Treasury state
    NFT. This is the regression test for P1.
26. `Register` rejects a treasury output that does not carry it.
27. `Register` rejects a treasury output at a different address.
28. `Deregister` repeats test 25.

**`lib/bifrost/types/config.ak`**

29. `config_getters_match_datum_fields` extended to pin all 12 top-level indexes
    and all 8 `params` indexes.

**`validators/bitcoin/config.ak`**

30. The existing mint and spend tests pass with the `"BIFCFG"` constant in place
    of the `t_asset_name` parameter. The fixture constant is deleted, not
    renamed, so a leftover parameter fails to compile.

The existing BIP340 vectors `t_updatey_sig` and `t_updatey_fed_sig` are reused
unchanged, because `rotation_sig_msg` does not change.

## Deployment

Order:

1. Choose the Config one-shot outpoint. The asset name is the `"BIFCFG"`
   constant and is not a deployment choice.
2. Build `config.ak`. Record the policy id.
3. Build `treasury.ak` with the Config policy id and its own one-shot outpoint.
   Record the policy id.
4. Build `spos_registry` with the treasury policy id. Record the policy id.
5. Build every remaining validator.
6. Mint the Config NFT with a datum naming every hash from steps 2 to 5.
7. Mint the Treasury state NFT and the registry root.

Steps 6 and 7 MAY share a transaction. `treasury.ak`'s mint branch does not read
the Config UTxO, so no ordering constraint exists between them.

## Work order

1. `lib/bifrost/constants.ak`, `lib/bifrost/types/treasury.ak`,
   `lib/bifrost/types/config.ak`.
2. `validators/bitcoin/config.ak`: drop the asset-name parameter, rebuild the
   test fixture.
3. `peg-in.ak`, `peg-out.ak`, `bridged-token.ak` and
   `completed-peg-ins-merkle-tree.ak`: drop the asset-name parameter, update the
   index-map comments.
4. `validators/bitcoin/treasury.ak` and its tests.
5. `validators/bitcoin/spos-registry.ak` and its tests.
6. `documentation/technical_documentation.md`.
7. heimdall, in its own repository and its own commit.

Steps 1 to 5 share a working tree and must land together. The suite must be
green before the commit.
