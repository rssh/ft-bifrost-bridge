# Treasury Refactor Implementation Plan

> **For agentic workers:** This repository does NOT use
> `superpowers:subagent-driven-development` or `superpowers:executing-plans`
> (see `CLAUDE.md`). Execute this plan with `/bifrost-dev
> docs/superpowers/specs/2026-08-12-treasury-refactor-design.md`, or work the
> tasks inline in order. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Treasury state UTxO an enforceable identity, so
`spos-registry.ak` can no longer be pointed at a forged one.

**Architecture:** `treasury_info` is parameterized by a one-shot outpoint and
the Config NFT policy id, and its own NFT name becomes the constant
`"BFRTRY"`. It reads the registry policy id and `y_federation` from the Config
datum instead of taking a registry parameter. That breaks the parameter cycle,
so `spo_registry` can take `treasury_policy_id` as a compile parameter and pin
the UTxO it updates. `ConfigDatum` is re-indexed at the same time: identities
and keys top level, tunables inside `params`, `params` at index 1.

**Tech Stack:** Aiken v1.1.23, Plutus V3, `aiken-lang/stdlib` v2.2.0,
`aiken-lang/merkle-patricia-forestry` v2.1.0,
`anastasia-labs/aiken-design-patterns` v1.2.0.

## Global Constraints

- Source spec: `docs/superpowers/specs/2026-08-12-treasury-refactor-design.md`.
  Where this plan and the spec disagree, the spec wins.
- All work is in `onchain/`. Run every command from `onchain/`.
- Full suite: `aiken check`. Single test: `aiken check -m "<test_name>" -e`.
  Module: `aiken check -m treasury`.
- Enter the environment with `nix develop` if `aiken` is not on PATH.
- Cite the spec ID from the code that implements it, as `// spec [TSY-3]`.
  This is the repository rule in `CLAUDE.md` §Traceability.
- Never renumber a spec ID.
- The Treasury state NFT asset name is `"BFRTRY"`, exactly.
- The Config NFT asset name is `"BIFCFG"`, exactly.
- The Update-Y signed message does NOT change. `rotation_sig_msg` keeps its
  current body, so the existing BIP340 vectors stay valid.
- Do NOT commit inside `offchain/SPO/heimdall` or
  `offchain/bitcoin-watchtower/binocular`. They are submodules. heimdall work
  is out of scope for this plan.
- Commit messages: no `Co-Authored-By` trailer, no em dashes.

---

### Task 1: Constants and the treasury pin helper

**Files:**
- Modify: `onchain/lib/bifrost/constants.ak`
- Modify: `onchain/lib/bifrost/utils.ak` (add helper + first tests in the file)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `constants.treasury_info_nft_asset_name : ByteArray` = `"BFRTRY"`
  - `constants.config_nft_asset_name : ByteArray` = `"BIFCFG"`
  - `utils.treasury_state_pinned(Input, Output, PolicyId) -> Bool`

- [ ] **Step 1: Set the two constants**

In `onchain/lib/bifrost/constants.ak`, replace the stale
`pub const treasury_info_nft_asset_name = ""` line and add the Config name:

```aiken
//spec [CFG-7]: the Config NFT asset name is a protocol constant, not a
//validator parameter. A parameter here has no safe failure mode: a deployment
//that passes another name leaves treasury.ak looking for a token that does not
//exist, and its Retire branch fails with it, so the Treasury state UTxO can
//never be spent again.
pub const config_nft_asset_name = "BIFCFG"

//Asset name of the Treasury state NFT (spec §Treasury state UTxO). A constant,
//not sha256 of the bootstrap outpoint: uniqueness comes from the one-shot
//outpoint baked into the policy id.
pub const treasury_info_nft_asset_name = "BFRTRY"
```

- [ ] **Step 2: Write the failing tests for the pin helper**

`onchain/lib/bifrost/utils.ak` has no tests today. Append this block at the end
of the file:

```aiken
//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_treasury_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_other_policy: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fn t_treasury_address() -> Address {
  Address {
    payment_credential: Script(t_treasury_policy),
    stake_credential: None,
  }
}

fn t_pin_value(policy: ByteArray, name: ByteArray, qty: Int) -> Value {
  assets.from_lovelace(2_000_000) |> assets.add(policy, name, qty)
}

fn t_pin_output(value: Value, address: Address) -> Output {
  Output { address, value, datum: NoDatum, reference_script: None }
}

fn t_pin_input(value: Value, address: Address) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: t_pin_output(value, address),
  }
}

fn t_good_value() -> Value {
  t_pin_value(t_treasury_policy, constants.treasury_info_nft_asset_name, 1)
}

// spec [REG-6], [REG-7], [REG-8]: a real Treasury state UTxO passes.
test treasury_state_pinned_happy() {
  treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: an input with no Treasury state NFT is rejected. This is the
// decoy the registry accepted before the pin existed.
test treasury_state_pinned_rejects_input_without_nft() {
  !treasury_state_pinned(
    t_pin_input(assets.from_lovelace(2_000_000), t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: the right name under a foreign policy is not the NFT.
test treasury_state_pinned_rejects_foreign_policy() {
  let forged =
    t_pin_value(t_other_policy, constants.treasury_info_nft_asset_name, 1)
  !treasury_state_pinned(
    t_pin_input(forged, t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-6]: the right policy under a wrong name is not the NFT.
test treasury_state_pinned_rejects_wrong_name() {
  let forged = t_pin_value(t_treasury_policy, "NOTBFR", 1)
  !treasury_state_pinned(
    t_pin_input(forged, t_treasury_address()),
    t_pin_output(t_good_value(), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-7]: the NFT must continue into the output.
test treasury_state_pinned_rejects_output_without_nft() {
  !treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(assets.from_lovelace(2_000_000), t_treasury_address()),
    t_treasury_policy,
  )
}

// spec [REG-8]: the output must stay at the same address.
test treasury_state_pinned_rejects_moved_output() {
  let elsewhere =
    Address {
      payment_credential: Script(t_other_policy),
      stake_credential: None,
    }
  !treasury_state_pinned(
    t_pin_input(t_good_value(), t_treasury_address()),
    t_pin_output(t_good_value(), elsewhere),
    t_treasury_policy,
  )
}

// spec [REG-6]: two copies is not one.
test treasury_state_pinned_rejects_quantity_two() {
  let doubled =
    t_pin_value(t_treasury_policy, constants.treasury_info_nft_asset_name, 2)
  !treasury_state_pinned(
    t_pin_input(doubled, t_treasury_address()),
    t_pin_output(doubled, t_treasury_address()),
    t_treasury_policy,
  )
}
```

The imports at the top of `utils.ak` must gain `Address` and `NoDatum`. Change
the two existing lines to:

```aiken
use bifrost/constants
use cardano/address.{Address, Script}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `aiken check -m utils`

Expected: compile error, `unknown function treasury_state_pinned`. That is the
failing state for this task. Do not proceed until you see it.

- [ ] **Step 4: Write the helper**

Add to `onchain/lib/bifrost/utils.ak`, above the test block:

```aiken
/// The check that a UTxO presented as the Treasury state UTxO really is it.
///
/// spec [REG-6], [REG-7], [REG-8]. Before this existed `spos-registry.ak`
/// located the Treasury state UTxO by redeemer index alone, so a registrant
/// could point the index at a wallet UTxO carrying a `TreasuryDatum`-shaped
/// datum, satisfy the [REG-5] absence proof against a trie it chose, and
/// register a duplicate `bifrost_id_pk` while the real identity root stood
/// still.
///
/// The address equality is not redundant with the NFT checks. The NFT proves
/// which token is present; the address is what keeps the continuing UTxO under
/// `treasury.ak`'s control.
pub fn treasury_state_pinned(
  treasury_input: Input,
  treasury_output: Output,
  treasury_policy_id: PolicyId,
) -> Bool {
  and {
    quantity_of(
      treasury_input.output.value,
      treasury_policy_id,
      constants.treasury_info_nft_asset_name,
    ) == 1,
    quantity_of(
      treasury_output.value,
      treasury_policy_id,
      constants.treasury_info_nft_asset_name,
    ) == 1,
    treasury_output.address == treasury_input.output.address,
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `aiken check -m utils`

Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add onchain/lib/bifrost/constants.ak onchain/lib/bifrost/utils.ak
git commit -m "feat(onchain): name the two NFT constants, and add the treasury pin helper

The Treasury state NFT name becomes \"BFRTRY\" and the Config NFT name becomes
\"BIFCFG\", both protocol constants. treasury_state_pinned is the check
spos-registry.ak has been missing: NFT on the input, NFT on the output, and the
output still at the input's address."
```

---

### Task 2: Re-index `ConfigDatum`

**Files:**
- Modify: `onchain/lib/bifrost/types/config.ak`
- Modify: `onchain/validators/bitcoin/config.ak` (test fixture only)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces, for later tasks:
  - `ConfigDatum` with 12 fields, `params` at index 1, `y_federation` at 11.
  - `ConfigParams` with 8 fields, `schedule` at 0, `federation_csv_blocks` at 7.
  - `config.get_spos_registry_policy_id(List<Data>) -> PolicyId` (index 9)
  - `config.get_y_federation(List<Data>) -> ByteArray` (index 11)
  - `config.get_federation_csv_blocks(List<Data>) -> Int` (params index 7)
  - `get_treasury_info_asset_name` is DELETED.

- [ ] **Step 1: Rewrite the two records**

In `onchain/lib/bifrost/types/config.ak`, replace `ConfigDatum` and
`ConfigParams` with:

```aiken
//The rev-5.5 twelve-field Config datum (spec §Config datum). Two rules decide
//where a field goes.
//
//spec [CFG-6]: an identity or a key is a TOP-LEVEL field; a tunable number
//lives inside `params`. That is why `y_federation` (a key) sits at index 11
//while `federation_csv_blocks` (a block count) sits inside `params`.
//
//spec [CFG-5]: a new field is APPENDED at the tail, never inserted, and
//`params` sits at index 1 and never moves. The rev-5.4 layout put `params`
//last and told the reader to append after it, which invites exactly the edit
//that breaks every index: insert before `params` to keep it last. At index 1
//there is no "last" property left to preserve.
//
//Removed in rev 5.5:
//- treasury_info_asset_name: the Treasury state NFT name is the "BFRTRY"
//  constant in bifrost/constants, so the field had nothing left to say.
pub type ConfigDatum {
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //Every value with no on-chain reader. Index 1 and frozen there.
  params: ConfigParams,
  //fBTC policy id
  bridged_token_policy: PolicyId,
  //CPI trie NFT policy
  completed_peg_ins_policy: PolicyId,
  //Bridge state singleton NFT policy
  bridge_state_policy: PolicyId,
  //spec [CFG-2]: the TM validator hash (= TM NFT policy id). NO on-chain
  //reader; published so off-chain readers can locate the TM address.
  tm_script_hash: ByteArray,
  peg_in_script_hash: ByteArray,
  peg_out_script_hash: ByteArray,
  //The DEPLOYED spo_bans policy id; the ban script address follows from it.
  spo_bans_policy_id: PolicyId,
  //The DEPLOYED spos_registry policy id. spec [PRE-4]: treasury.ak reads this
  //to gate its RegistryUpdate branch, so this field has an on-chain reader for
  //the first time. treasury.ak cannot take it as a parameter without
  //recreating the dependency cycle that made the registry pin impossible.
  spos_registry_policy_id: PolicyId,
  //The DEPLOYED treasury_info policy id. Off-chain discovery only: the pin is
  //a compile parameter of spos_registry, not this field.
  treasury_info_policy_id: PolicyId,
  //The federation fallback key (script-leaf key of both Taproot trees). Moved
  //here from TreasuryDatum in rev 5.5: nothing rotated it in the datum, and
  //here an ordinary Config Update rotates it, which is the federation-key
  //rotation the field-permission matrix always promised.
  y_federation: ByteArray,
}

//Every value with no on-chain reader (spec [CFG-6]). Governance replaces the
//record wholesale. `schedule` sits at index 0 and never moves, for the same
//reason `params` sits at index 1.
pub type ConfigParams {
  //Epoch/TM schedule.
  schedule: ScheduleParams,
  //Exact miner fee rate (sat/vB) for deterministic TM construction.
  fee_rate_sat_per_vb: Int,
  //Floor (satoshi) for the per-peg-out protocol fee.
  per_pegout_fee: Int,
  //Minimum bridged-token amount (satoshi) a PegOut may lock.
  min_peg_out_fbtc: Int,
  //Ban schedule, mirroring what spo_bans was parameterized with.
  base_ban_duration_ms: Int,
  max_faults_before_permanent: Int,
  max_validity_window_ms: Int,
  //The CSV timeout baked into the federation Taproot leaves. A block count,
  //so [CFG-6] puts it here and not next to y_federation.
  federation_csv_blocks: Int,
}
```

Delete the stray comment lines about `treasury_info_asset_name` if the editor
leaves a duplicate; the record above is the whole definition.

- [ ] **Step 2: Rewrite the getters**

Replace every getter between the getters banner comment and the pinning test
with exactly these, in this order:

```aiken
pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 0)
  update_auth
}

//The nested params record (ConfigDatum field 1) as its raw fields list.
//Indexes inside it live only in the getters below.
fn get_params_fields(config_fields: List<Data>) -> List<Data> {
  builtin.unconstr_fields(safe_list_at(config_fields, 1))
}

pub fn get_bridged_token_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_completed_peg_ins_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_bridge_state_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

//spec [CFG-2]: NO on-chain reader. Off-chain/test use only.
pub fn get_tm_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

pub fn get_peg_in_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 6))
}

pub fn get_peg_out_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 7))
}

pub fn get_spo_bans_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 8))
}

//spec [PRE-4]: read on-chain by treasury.ak's RegistryUpdate branch.
pub fn get_spos_registry_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 9))
}

pub fn get_treasury_info_policy_id(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 10))
}

//spec [UY-5]: read on-chain by treasury.ak's UpdateY branch, which accepts a
//BIP340 signature under this key as the federation's standing co-authority.
pub fn get_y_federation(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 11))
}

//Off-chain/test use only. A FULL cast of the nested record, so an on-chain
//reader adopting it would freeze ScheduleParams' inner shape.
pub fn get_schedule(config_fields: List<Data>) -> ScheduleParams {
  expect schedule: ScheduleParams =
    safe_list_at(get_params_fields(config_fields), 0)
  schedule
}

pub fn get_fee_rate_sat_per_vb(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 1))
}

pub fn get_per_pegout_fee(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 2))
}

pub fn get_min_peg_out_fbtc(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 3))
}

pub fn get_base_ban_duration_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 4))
}

pub fn get_max_faults_before_permanent(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 5))
}

pub fn get_max_validity_window_ms(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 6))
}

pub fn get_federation_csv_blocks(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 7))
}
```

`get_treasury_info_asset_name` is deleted. Do not leave a stub.

- [ ] **Step 3: Rewrite the pinning test**

Replace `config_getters_match_datum_fields` with:

```aiken
//Pins every getter index to its ConfigDatum record field. Every field carries
//a distinct value, so a reordering of the record relative to the getters fails
//this test even when the swapped fields share a type.
test config_getters_match_datum_fields() {
  let schedule =
    ScheduleParams {
      dkg_r1_deadline: 3600,
      dkg_r2_deadline: 7200,
      update_y_deadline: 10800,
      tm_batch_interval: 21600,
      sign_r1_window: 1800,
      sign_r2_window: 1800,
      leader_slot_t: 600,
      tm_recovery_window: 129600,
      final_tm_cutoff: 345600,
      stability_window: 129600,
    }
  let params =
    ConfigParams {
      schedule,
      fee_rate_sat_per_vb: 21,
      per_pegout_fee: 22,
      min_peg_out_fbtc: 23,
      base_ban_duration_ms: 24,
      max_faults_before_permanent: 25,
      max_validity_window_ms: 26,
      federation_csv_blocks: 27,
    }
  let datum =
    ConfigDatum {
      update_auth: Some(CardanoSignature { hash: #"aa00" }),
      params,
      bridged_token_policy: #"aa02",
      completed_peg_ins_policy: #"aa03",
      bridge_state_policy: #"aa04",
      tm_script_hash: #"aa05",
      peg_in_script_hash: #"aa06",
      peg_out_script_hash: #"aa07",
      spo_bans_policy_id: #"aa08",
      spos_registry_policy_id: #"aa09",
      treasury_info_policy_id: #"aa10",
      y_federation: #"aa11",
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    //index 0
    get_update_auth(fields) == datum.update_auth,
    //index 2
    get_bridged_token_policy(fields) == datum.bridged_token_policy,
    //index 3
    get_completed_peg_ins_policy(fields) == datum.completed_peg_ins_policy,
    //index 4
    get_bridge_state_policy(fields) == datum.bridge_state_policy,
    //index 5, spec [CFG-2]
    get_tm_script_hash(fields) == datum.tm_script_hash,
    //index 6
    get_peg_in_script_hash(fields) == datum.peg_in_script_hash,
    //index 7
    get_peg_out_script_hash(fields) == datum.peg_out_script_hash,
    //index 8
    get_spo_bans_policy_id(fields) == datum.spo_bans_policy_id,
    //index 9, spec [PRE-4]
    get_spos_registry_policy_id(fields) == datum.spos_registry_policy_id,
    //index 10
    get_treasury_info_policy_id(fields) == datum.treasury_info_policy_id,
    //index 11, spec [UY-5]
    get_y_federation(fields) == datum.y_federation,
    //index 1, the nested params record
    get_schedule(fields) == params.schedule,
    get_fee_rate_sat_per_vb(fields) == params.fee_rate_sat_per_vb,
    get_per_pegout_fee(fields) == params.per_pegout_fee,
    get_min_peg_out_fbtc(fields) == params.min_peg_out_fbtc,
    get_base_ban_duration_ms(fields) == params.base_ban_duration_ms,
    get_max_faults_before_permanent(fields) == params.max_faults_before_permanent,
    get_max_validity_window_ms(fields) == params.max_validity_window_ms,
    get_federation_csv_blocks(fields) == params.federation_csv_blocks,
  }
}
```

- [ ] **Step 4: Run the test to verify the shape is enforced**

Run: `aiken check -m "bifrost/types/config"`

Expected: PASS. If it fails, a getter index does not match its record position.
Fix the getter, not the test.

- [ ] **Step 5: Rebuild the `config.ak` raw fixture**

`onchain/validators/bitcoin/config.ak` builds the datum as raw `Data`. Replace
`t_datum_data` with the 12-field version:

```aiken
//The rev-5.5 twelve-field Config datum (spec §Config datum), built as raw
//Data: 0 update_auth, 1 params, 2 bridged_token_policy,
//3 completed_peg_ins_policy, 4 bridge_state_policy, 5 tm_script_hash [CFG-2],
//6 peg_in_script_hash, 7 peg_out_script_hash, 8 spo_bans_policy_id,
//9 spos_registry_policy_id, 10 treasury_info_policy_id, 11 y_federation.
//Raw on purpose: the spend handler takes the datum raw, so the fixture mirrors
//the wire encoding and stays valid across a future shape evolution.
fn t_datum_data(update_auth: Option<AuthorizationMethod>) -> Data {
  let update_auth_data: Data = update_auth
  let schedule_data: Data =
    ScheduleParams {
      dkg_r1_deadline: 3600,
      dkg_r2_deadline: 7200,
      update_y_deadline: 10800,
      tm_batch_interval: 21600,
      sign_r1_window: 1800,
      sign_r2_window: 1800,
      leader_slot_t: 600,
      tm_recovery_window: 129600,
      final_tm_cutoff: 345600,
      stability_window: 129600,
    }
  let params_data: Data =
    builtin.constr_data(
      0,
      [
        schedule_data,
        builtin.i_data(1),
        builtin.i_data(1000),
        builtin.i_data(10000),
        builtin.i_data(600_000),
        builtin.i_data(3),
        builtin.i_data(3_600_000),
        builtin.i_data(144),
      ],
    )
  builtin.constr_data(
    0,
    [
      update_auth_data,
      params_data,
      builtin.b_data(#"aa111111111111111111111111111111111111111111111111111111"),
      builtin.b_data(#"aa444444444444444444444444444444444444444444444444444444"),
      builtin.b_data(#"aa555555555555555555555555555555555555555555555555555555"),
      builtin.b_data(#"aa888888888888888888888888888888888888888888888888888888"),
      builtin.b_data(#"aa666666666666666666666666666666666666666666666666666666"),
      builtin.b_data(#"aa777777777777777777777777777777777777777777777777777777"),
      builtin.b_data(#"aabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
      builtin.b_data(#"aacccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
      builtin.b_data(#"aadddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
      builtin.b_data(#"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"),
    ],
  )
}
```

`t_edited_datum` rewrites field 5 today. Field 5 is now `tm_script_hash`, which
is still a `ByteArray`, so `t_set_field(datum_data, 5, ...)` keeps working. Only
its comment needs updating: change "rewrite field 5 (peg_in_script_hash)" to
"rewrite field 5 (tm_script_hash)".

`update_allows_changing_bridged_token_identity` rewrites field 1. Field 1 is now
`params`, not `bridged_token_policy`. Change that test to rewrite field 2:

```aiken
test update_allows_changing_bridged_token_identity() {
  let old_datum = t_datum_data(Some(CardanoSignature { hash: t_dev_pkh }))
  let new_datum =
    t_set_field(
      old_datum,
      2,
      builtin.b_data(#"ff222222222222222222222222222222222222222222222222222222"),
    )
  let tx = t_update_tx(old_datum, [t_config_output(new_datum)])
  t_spend(old_datum, Update, tx)
}
```

- [ ] **Step 6: Run the config suite**

Run: `aiken check -m config`

Expected: all 26 tests pass (25 in the validator, 1 in the types module).

- [ ] **Step 7: Commit**

```bash
git add onchain/lib/bifrost/types/config.ak onchain/validators/bitcoin/config.ak
git commit -m "feat(onchain): re-index ConfigDatum, params first, federation key top level

Twelve top-level fields, eight in params. [CFG-6] decides placement: an
identity or a key is top level, a tunable number lives in params. y_federation
arrives from TreasuryDatum and federation_csv_blocks joins the tunables.
treasury_info_asset_name is gone with its getter, replaced by the \"BFRTRY\"
constant.

params moves to index 1. Under the append rule its old tail position never
drifted either, but the comment that guarded it opened with \"params comes
LAST\", which invites the one edit that shifts every index. At index 1 there is
no last property to preserve."
```

---

### Task 3: Drop the Config asset-name parameter from five validators

**Files:**
- Modify: `onchain/validators/bitcoin/config.ak:20`
- Modify: `onchain/validators/bitcoin/peg-in.ak:98`
- Modify: `onchain/validators/bitcoin/peg-out.ak:30`
- Modify: `onchain/validators/bitcoin/bridged-token.ak:28`
- Modify: `onchain/validators/bitcoin/completed-peg-ins-merkle-tree.ak:23`

**Interfaces:**
- Consumes: `constants.config_nft_asset_name` from Task 1.
- Produces: five validators whose parameter lists no longer carry the name.

This task has no new test. It is a signature change, and the existing 62 tests
across these five files are the regression net. Every test call site that still
passes the argument fails to compile, and the compiler enumerates them.

- [ ] **Step 1: `config.ak`**

Change the declaration and every use of the parameter:

```aiken
validator config(tx0: ByteArray, index0: Int) {
```

Inside the validator, replace each `config_asset_name` with
`constants.config_nft_asset_name`. There are five uses: lines 42, 44, 53, 115
and 125 in the current file. Add `use bifrost/constants` to the imports.

In the test section, delete `const t_asset_name` and replace its uses with
`constants.config_nft_asset_name`. Delete the third argument from the two
handler call sites: `t_spend` (which calls `config.spend`) and the four
`config.mint(...)` calls in the mint tests.

- [ ] **Step 2: `peg-in.ak`**

```aiken
validator peg_in_validator(
  oracle_policy_id: PolicyId,
  config_nft_policy_id: PolicyId,
) {
```

At the `utils.get_config_as_data_list` call (currently line 223), replace the
`config_nft_asset_name` argument with `constants.config_nft_asset_name`.
`constants` is already imported in this file.

In the tests, delete `t_config_asset` and drop the argument from the
`peg_in_validator.mint(...)` call at line 1301 and from every other handler call
the compiler reports.

- [ ] **Step 3: `peg-out.ak`**

```aiken
validator peg_out_validator(config_nft_policy_id: ByteArray) {
```

Replace the argument at the `get_config_as_data_list` call (line 40) with
`constants.config_nft_asset_name`. In the tests, drop the second argument from
the `peg_out_validator.withdraw(...)` call inside the `t_withdraw` helper
(line 441), and delete `t_config_asset`.

- [ ] **Step 4: `bridged-token.ak`**

```aiken
validator bridged_token(configNFTPolicyId: ByteArray) {
```

Replace the argument at line 38 with `constants.config_nft_asset_name`. In the
tests, drop the second argument from `bridged_token.mint(...)` at line 166.

- [ ] **Step 5: `completed-peg-ins-merkle-tree.ak`**

```aiken
validator completed_peg_ins_merkle_tree_validator(
  configNFTPolicyId: ByteArray,
  one_shot_input_ref: OutputReference,
) {
```

Replace the argument at line 76 with `constants.config_nft_asset_name`. This
file has no tests, so nothing else changes.

- [ ] **Step 6: Run the whole suite**

Run: `aiken check`

Expected: every test passes. If a call site still passes the old argument, the
compiler names the file and line. Fix and re-run.

- [ ] **Step 7: Commit**

```bash
git add onchain/validators/bitcoin/
git commit -m "feat(onchain): the Config NFT name is a constant, not a parameter [CFG-7]

Five validators took the name as a compile parameter. Keeping it a parameter in
five places while treasury.ak reads a constant has no safe failure mode: one
divergent deployment argument and treasury.ak searches for a token that does
not exist, so every branch fails, Retire included, and the Treasury state UTxO
can never be spent again.

The name never separated two instances anyway. The Config policy id is
config.ak hashed with its own one-shot outpoint, so two instances on one
network stay distinct. Same conversion [CFG-1] made for \"fSAT\"."
```

---

### Task 4: `treasury.ak` types, skeleton, and the bootstrap mint

**Files:**
- Rewrite: `onchain/lib/bifrost/types/treasury.ak`
- Rewrite: `onchain/validators/bitcoin/treasury.ak`

**Interfaces:**
- Consumes: `constants.treasury_info_nft_asset_name`,
  `constants.config_nft_asset_name` (Task 1); `config.get_y_federation`,
  `config.get_spos_registry_policy_id` (Task 2).
- Produces:
  - `TreasuryDatum { bifrost_identity_root: ByteArray, current_spos_frost_key: ByteArray }`
  - `TreasurySpendRedeemer` with `RegistryUpdate`, `UpdateY`, `Retire`
  - `validator treasury_info(tx0: ByteArray, index0: Int, config_policy_id: PolicyId)`

- [ ] **Step 1: Rewrite the types module**

Replace the whole of `onchain/lib/bifrost/types/treasury.ak` with:

```aiken
// Treasury state datum (normative — technical_documentation.md §Treasury state
// UTxO). Rev 5.5 cut it to two fields:
//   #0 bifrost_identity_root  — MPF root of active bifrost_id_pk -> pool_id
//   #1 current_spos_frost_key — Y_51 after the first DKG; Y_federation until then
//
// Gone in rev 5.5:
// - last_reset_tm_txid: inert since its only writer, the FederationReset
//   branch, was withdrawn ([UY-7], [UY-8]).
// - y_federation, federation_csv_blocks: instance configuration, not state.
//   Nothing here ever rotated them. They live in the Config datum now, where an
//   ordinary Update rotates them.
//
// spec [TSY-1]: exactly two fields, decoded as a type and read by name per
// [LIB-1]. Only ConfigDatum must stay append-extensible, because every contract
// is parameterized by the Config NFT and so the Config alone cannot be swapped.
// This UTxO sits behind its own NFT, and replacing it is a bootstrap.
pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  current_spos_frost_key: ByteArray,
}

// No mint redeemer. The one-shot outpoint is a validator parameter and the
// asset name is a constant, so the mint has nothing left to be told.

pub type TreasurySpendRedeemer {
  // Registry-coupled root update (Register / Deregister). Only
  // bifrost_identity_root may change. spec [TSY-12]: the registry policy id
  // comes from the Config datum, never from a parameter — a parameter here
  // would recreate the cycle that made the registry-side pin impossible.
  RegistryUpdate { new_bifrost_identity_root: ByteArray, config_ref_input_index: Int }
  // Update-Y (DKG key rotation): only current_spos_frost_key changes,
  // authorized by a BIP340 signature over
  //   sha2_256("bifrost-update-y" ++ spent_outpoint(36B: txid ++ vout LE)
  //            ++ epoch(8B BE) ++ new_spos_frost_key(32B)).
  // The signer is the OUTGOING datum's current_spos_frost_key, or — spec
  // [UY-5] — the Config's y_federation, the federation's standing co-authority.
  // Submission is permissionless: the signature is the authorization and the
  // message commits to the spent outpoint, so it cannot be replayed.
  UpdateY {
    new_spos_frost_key: ByteArray,
    epoch: Int,
    signature: ByteArray,
    config_ref_input_index: Int,
  }
  // Instance teardown. spec [TSY-19]: gated on the Config NFT burn, and on
  // nothing else. Burning the Config NFT necessarily spends the Config UTxO,
  // which runs config.ak's own Retire branch under update_auth, so governance
  // authorization is inherited rather than duplicated.
  Retire
}
```

- [ ] **Step 2: Write the failing bootstrap tests**

Replace the whole of `onchain/validators/bitcoin/treasury.ak` with the imports,
the skeleton validator, the fixtures and the bootstrap tests below. The three
spend branches are `False` for now; Tasks 5 to 7 fill them in.

```aiken
use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use bifrost/constants
use bifrost/types/config as config_types
use bifrost/types/treasury.{
  RegistryUpdate, Retire, TreasuryDatum, TreasurySpendRedeemer, UpdateY,
}
use bifrost/utils
use cardano/address.{Address, Inline, Script}
use cardano/assets.{PolicyId, flatten, quantity_of, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
  placeholder,
}

// The domain-separated preimage a key rotation signs. UNCHANGED in rev 5.5, so
// every BIP340 vector below and in heimdall stays valid. `tag` stays a
// parameter so heimdall's signer and this verifier agree byte-for-byte (see
// technical_documentation.md §Update-Y).
fn rotation_sig_msg(
  tag: ByteArray,
  own_ref: OutputReference,
  epoch: Int,
  new_key: ByteArray,
) -> ByteArray {
  crypto.sha2_256(
    tag
      |> bytearray.concat(own_ref.transaction_id)
      |> bytearray.concat(bytearray.from_int_little_endian(own_ref.output_index, 4))
      |> bytearray.concat(bytearray.from_int_big_endian(epoch, 8))
      |> bytearray.concat(new_key),
  )
}

// spec [PRE-1] REVISED: treasury.ak takes neither tm_nft_policy_id nor
// registry_policy_id. A compile parameter naming another bridge script breaks
// permanently on that script's redeploy, and this script's state UTxO can never
// move. spec [PRE-3]: the Config NFT policy id is the one identity safe to bake
// in — the Config UTxO is the root of the identity graph, and its policy id
// depends only on its own one-shot outpoint.
validator treasury_info(tx0: ByteArray, index0: Int, config_policy_id: PolicyId) {
  // STUB until Step 4.
  mint(_redeemer: Data, _policy_id: PolicyId, _self: Transaction) {
    False
  }

  spend(
    _datum: Option<TreasuryDatum>,
    _redeemer: TreasurySpendRedeemer,
    _own_ref: OutputReference,
    _self: Transaction,
  ) {
    False
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Test fixtures
//----------------------------------------------------------------------------

const t_own_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_policy: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_registry_policy: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_tx0: ByteArray =
  #"0101010101010101010101010101010101010101010101010101010101010101"

const t_index0: Int = 0

// Federation key: x-only of secret 3, so the [UY-5] federation test can sign
// under it. It lives in the CONFIG datum now, not in TreasuryDatum.
const t_yfed: ByteArray =
  #"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

// Update-Y BIP340 vector. t_cur_key is the x-only generator point (secret 1),
// which signs the rotation to t_new_key. rotation_sig_msg is unchanged in rev
// 5.5, so this vector is the rev-5.4 one, reused verbatim.
const t_cur_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

const t_new_key: ByteArray =
  #"abababababababababababababababababababababababababababababababab"

const t_updatey_txid: ByteArray =
  #"2222222222222222222222222222222222222222222222222222222222222222"

const t_updatey_epoch: Int = 7

const t_updatey_sig: ByteArray =
  #"21e3f8a17eac410867d72aea6a9089001153682a481861188527008e698c8d857e3454db7e2e413f0ae8a2aadedcc4d5f33934b6f5e066d9202cb78a591dcd21"

// spec [UY-5]: the SAME message, signed by the FEDERATION key (secret 3).
const t_updatey_fed_sig: ByteArray =
  #"c5a6acf9ad7895ef37f63bdca615f21b73d2b08d0bdc244b36d53abb63cab264252a857c22522daebb7deec35b2066d72f5dc678413a1ca7ce7a018340018d53"

fn t_datum(root: ByteArray, key: ByteArray) -> TreasuryDatum {
  TreasuryDatum { bifrost_identity_root: root, current_spos_frost_key: key }
}

// A typed ConfigDatum, on purpose. The treasury reads it positionally through
// the getters, and building the real record here means a ConfigDatum shape
// change surfaces in these tests instead of silently shifting an index.
fn t_config_datum() -> config_types.ConfigDatum {
  config_types.ConfigDatum {
    update_auth: None,
    params: config_types.ConfigParams {
      schedule: config_types.ScheduleParams {
        dkg_r1_deadline: 3600,
        dkg_r2_deadline: 7200,
        update_y_deadline: 10800,
        tm_batch_interval: 21600,
        sign_r1_window: 1800,
        sign_r2_window: 1800,
        leader_slot_t: 600,
        tm_recovery_window: 129600,
        final_tm_cutoff: 345600,
        stability_window: 129600,
      },
      fee_rate_sat_per_vb: 1,
      per_pegout_fee: 1000,
      min_peg_out_fbtc: 10000,
      base_ban_duration_ms: 600_000,
      max_faults_before_permanent: 3,
      max_validity_window_ms: 3_600_000,
      federation_csv_blocks: 144,
    },
    bridged_token_policy: #"aa02",
    completed_peg_ins_policy: #"aa03",
    bridge_state_policy: #"aa04",
    tm_script_hash: #"aa05",
    peg_in_script_hash: #"aa06",
    peg_out_script_hash: #"aa07",
    spo_bans_policy_id: #"aa08",
    spos_registry_policy_id: t_registry_policy,
    treasury_info_policy_id: t_own_hash,
    y_federation: t_yfed,
  }
}

// `with_nft = False` is the [TSY-12] negative: a reference input that carries
// the datum but not the Config NFT must not be trusted.
fn t_config_ref_input(with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_config_policy, constants.config_nft_asset_name, 1)
    } else {
      base
    }
  let datum_data: Data = t_config_datum()
  Input {
    output_reference: OutputReference {
      transaction_id: #"3333333333333333333333333333333333333333333333333333333333333333",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value: value,
      datum: InlineDatum(datum_data),
      reference_script: None,
    },
  }
}

fn t_treasury_value() -> assets.Value {
  assets.from_lovelace(2_000_000)
    |> assets.add(t_own_hash, constants.treasury_info_nft_asset_name, 1)
}

fn t_script_address() -> Address {
  Address { payment_credential: Script(t_own_hash), stake_credential: None }
}

fn t_output(d: TreasuryDatum) -> Output {
  Output {
    address: t_script_address(),
    value: t_treasury_value(),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

// The one-shot outpoint the bootstrap consumes.
fn t_one_shot_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: t_tx0,
      output_index: t_index0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(
          #"ff999999999999999999999999999999999999999999999999999999",
        ),
        stake_credential: None,
      },
      value: assets.from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_mint_tx(inputs: List<Input>, outputs: List<Output>, mint: assets.Value) -> Transaction {
  Transaction { ..placeholder, inputs: inputs, outputs: outputs, mint: mint }
}

fn t_bootstrap_mint(qty: Int) -> assets.Value {
  assets.from_asset(t_own_hash, constants.treasury_info_nft_asset_name, qty)
}

//----------------------------------------------------------------------------
// Tests: bootstrap mint
//----------------------------------------------------------------------------

test mint_bootstrap_happy() {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [PRE-2]: a replacement deployment MAY seed a non-empty identity root.
test mint_bootstrap_accepts_seeded_identity_root() {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root1, t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-3]: without the one-shot outpoint the policy is not mintable.
test mint_bootstrap_rejects_missing_one_shot() fail {
  let tx =
    t_mint_tx([], [t_output(t_datum(t_root0, t_cur_key))], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-4]
test mint_bootstrap_rejects_wrong_asset_name() fail {
  let wrong_name = assets.from_asset(t_own_hash, "NOTBFR", 1)
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, "NOTBFR", 1),
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], wrong_name)
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-4]
test mint_bootstrap_rejects_quantity_two() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_own_hash, constants.treasury_info_nft_asset_name, 2),
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(2))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-6]: the state UTxO carries the NFT and nothing else.
test mint_bootstrap_rejects_extra_token() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: t_treasury_value()
        |> assets.add(
            #"ff444444444444444444444444444444444444444444444444444444",
            "junk",
            1,
          ),
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-5]: exactly one output at this script.
test mint_bootstrap_rejects_two_script_outputs() fail {
  let decoy =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      value: assets.from_lovelace(2_000_000),
    }
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, t_cur_key)), decoy],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-7]
test mint_bootstrap_rejects_undecodable_datum() fail {
  let output =
    Output { ..t_output(t_datum(t_root0, t_cur_key)), datum: InlineDatum(42) }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-8]: a short key is a typo, and it would brick Update-Y forever.
test mint_bootstrap_rejects_short_key() fail {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(t_root0, #"abab"))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-8]
test mint_bootstrap_rejects_short_root() fail {
  let tx =
    t_mint_tx(
      [t_one_shot_input()],
      [t_output(t_datum(#"0000", t_cur_key))],
      t_bootstrap_mint(1),
    )
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-5]: a stake credential would change the address, so a reader
// pinning the bare script address would not find the UTxO.
test mint_bootstrap_rejects_stake_credential() fail {
  let output =
    Output {
      ..t_output(t_datum(t_root0, t_cur_key)),
      address: Address {
        payment_credential: Script(t_own_hash),
        stake_credential: Some(
          Inline(Script(#"ff333333333333333333333333333333333333333333333333333333")),
        ),
      },
    }
  let tx = t_mint_tx([t_one_shot_input()], [output], t_bootstrap_mint(1))
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}
```

**Write the mint handler as a stub for now.** Its body is the single expression
`False`:

```aiken
  mint(_redeemer: Data, _policy_id: PolicyId, _self: Transaction) {
    False
  }
```

The real body arrives in Step 4. Everything else in the block above is final.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `aiken check -m "bitcoin/treasury"`

Expected: the two positive tests, `mint_bootstrap_happy` and
`mint_bootstrap_accepts_seeded_identity_root`, FAIL. The nine `fail` tests pass
trivially against the stub, which is expected and is why the positive pair is
the signal. Do not proceed until you see those two red.

- [ ] **Step 4: Write the mint handler**

Replace the stub with the real body. `policy_id` and `self` lose their
underscores:

```aiken
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    let own_policy_mint = utils.quantity_of_policy_id(self.mint, policy_id)
    if own_policy_mint > 0 {
      // spec [TSY-3]: the one-shot outpoint is what makes this NFT a singleton.
      // It is baked into policy_id, so only the deployer can ever reach here.
      let one_time_utxo = OutputReference(tx0, index0)
      expect Some(_input_present) = find_input(self.inputs, one_time_utxo)
      // spec [TSY-5]: exactly one output at this script.
      expect [treasury_output] =
        list.filter(
          self.outputs,
          fn(output) { output.address.payment_credential == Script(policy_id) },
        )
      // spec [TSY-6]: it holds the NFT and no other non-ADA asset.
      expect [(out_policy, out_name, 1)] =
        flatten(without_lovelace(treasury_output.value))
      // spec [TSY-7]: the datum decodes as TreasuryDatum.
      expect InlineDatum(datum_raw) = treasury_output.datum
      expect genesis: TreasuryDatum = datum_raw
      and {
        // spec [TSY-4]
        own_policy_mint == 1,
        quantity_of(
          self.mint,
          policy_id,
          constants.treasury_info_nft_asset_name,
        ) == 1,
        out_policy == policy_id,
        out_name == constants.treasury_info_nft_asset_name,
        // spec [TSY-5]
        treasury_output.address == Address {
          payment_credential: Script(policy_id),
          stake_credential: None,
        },
        // spec [TSY-8]. The VALUES are free: spec [PRE-2] lets a replacement
        // deployment seed a non-empty root and carry a registered roster
        // forward. Only the deployer can mint, so a value check here would be a
        // self-check, not a boundary.
        bytearray.length(genesis.bifrost_identity_root) == 32,
        bytearray.length(genesis.current_spos_frost_key) == 32,
      }
    } else {
      // spec [TSY-9], [TSY-10]: burn. No authorization here. The NFT only ever
      // sits at this script, so burning it requires spending the state UTxO,
      // which runs the Retire branch. config.ak makes the same argument.
      and {
        own_policy_mint == -1,
        quantity_of(
          self.mint,
          policy_id,
          constants.treasury_info_nft_asset_name,
        ) == -1,
      }
    }
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `aiken check -m "bitcoin/treasury"`

Expected: 11 tests pass. The spend handler is still `False` and has no tests
yet.

- [ ] **Step 6: Commit**

```bash
git add onchain/lib/bifrost/types/treasury.ak onchain/validators/bitcoin/treasury.ak
git commit -m "feat(onchain): treasury_info gets a one-shot identity and a constant name

The mint was one-shot per OUTPOINT, not per bridge, so anyone could mint a
rival Treasury state NFT with a datum of their choosing. Only an asset-name pin
told the real one apart, and no validator applied that pin. The one-shot
outpoint moves into the policy id, the name becomes \"BFRTRY\", and the mint
redeemer disappears with them: the deployer has nothing left to tell it.

The bootstrap datum is checked for shape and 32-byte fields, and its VALUES are
free. Only the deployer can reach this branch, so a value check would be a
self-check. That is what lands [PRE-2], which heimdall already implements and
warns about.

TreasuryDatum drops to two fields. y_federation and federation_csv_blocks moved
to the Config datum in the previous commit; last_reset_tm_txid is deleted."
```

---

### Task 5: The burn and `Retire` branches

**Files:**
- Modify: `onchain/validators/bitcoin/treasury.ak`

**Interfaces:**
- Consumes: everything from Task 4.
- Produces: a spendable-and-burnable Treasury state UTxO.

- [ ] **Step 1: Write the failing tests**

Append to the test section of `onchain/validators/bitcoin/treasury.ak`:

```aiken
//----------------------------------------------------------------------------
// Tests: burn and Retire
//----------------------------------------------------------------------------

fn t_own_ref() -> OutputReference {
  OutputReference { transaction_id: t_updatey_txid, output_index: 0 }
}

fn t_input(d: TreasuryDatum) -> Input {
  Input { output_reference: t_own_ref(), output: t_output(d) }
}

fn t_config_burn() -> assets.Value {
  assets.from_asset(t_config_policy, constants.config_nft_asset_name, -1)
}

fn t_treasury_burn() -> assets.Value {
  assets.from_asset(t_own_hash, constants.treasury_info_nft_asset_name, -1)
}

fn t_spend(
  d: TreasuryDatum,
  redeemer: TreasurySpendRedeemer,
  tx: Transaction,
) -> Bool {
  treasury_info.spend(
    t_tx0,
    t_index0,
    t_config_policy,
    Some(d),
    redeemer,
    t_own_ref(),
    tx,
  )
}

// spec [TSY-9]: the mint handler accepts the burn on its own. Authorization
// lives in the Retire branch, which the burn cannot avoid running.
test mint_burn_accepts_minus_one() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(t_datum(t_root0, t_cur_key))],
      mint: t_treasury_burn(),
    }
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-9]
test mint_burn_rejects_mixed_mint_and_burn() fail {
  let tx =
    Transaction {
      ..placeholder,
      mint: t_treasury_burn() |> assets.add(t_own_hash, "other", 1),
    }
  treasury_info.mint(t_tx0, t_index0, t_config_policy, Void, t_own_hash, tx)
}

// spec [TSY-19], [TSY-20], [TSY-21]: both NFTs burn, no continuing output.
test spend_retire_happy() {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [],
      mint: t_treasury_burn() |> assets.merge(t_config_burn()),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-19]: without the Config burn there is no inherited authorization,
// so anyone could tear the instance down.
test spend_retire_rejects_without_config_burn() fail {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [],
      mint: t_treasury_burn(),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-20]: Retire must not become a way to move the NFT somewhere else.
test spend_retire_rejects_without_treasury_burn() fail {
  let d = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d)],
      outputs: [t_output(d)],
      mint: t_config_burn(),
    }
  t_spend(d, Retire, tx)
}

// spec [TSY-11]: an input with no Treasury state NFT is not the state UTxO.
test spend_rejects_input_without_nft() fail {
  let d = t_datum(t_root0, t_cur_key)
  let bare =
    Input {
      output_reference: t_own_ref(),
      output: Output {
        ..t_output(d),
        value: assets.from_lovelace(2_000_000),
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [bare],
      outputs: [],
      mint: t_treasury_burn() |> assets.merge(t_config_burn()),
    }
  t_spend(d, Retire, tx)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `aiken check -m "bitcoin/treasury"`

Expected: `mint_burn_accepts_minus_one` passes already (Task 4 wrote the burn
branch), and `spend_retire_happy` FAILS because the spend handler returns
`False`.

- [ ] **Step 3: Implement the spend prologue and the `Retire` branch**

Replace the placeholder `spend` handler with:

```aiken
  spend(
    datum: Option<TreasuryDatum>,
    redeemer: TreasurySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(in_datum) = datum
    // spec [TSY-11]
    expect
      quantity_of(
        own_input.output.value,
        own_hash,
        constants.treasury_info_nft_asset_name,
      ) == 1

    when redeemer is {
      // spec [TSY-19] to [TSY-22]. No signature and no continuing output.
      // Burning the Config NFT requires spending the Config UTxO, which runs
      // config.ak's Retire under update_auth, so governance authorization is
      // inherited. Duplicating it here would add a second thing to keep in sync.
      Retire -> and {
          quantity_of(
            self.mint,
            config_policy_id,
            constants.config_nft_asset_name,
          ) == -1,
          quantity_of(
            self.mint,
            own_hash,
            constants.treasury_info_nft_asset_name,
          ) == -1,
        }
      RegistryUpdate { .. } -> False
      UpdateY { .. } -> False
    }
  }
```

`in_datum` is unused until Task 6. Prefix it as `_in_datum` for now and rename
it back in Task 6, or accept the compiler warning; do not delete the binding,
because both later branches need it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `aiken check -m "bitcoin/treasury"`

Expected: 17 tests pass.

- [ ] **Step 5: Commit**

```bash
git add onchain/validators/bitcoin/treasury.ak
git commit -m "feat(onchain): the Treasury state UTxO can be retired

Before this the NFT could never be burned and the UTxO could never be closed:
the mint branch demanded a quantity of exactly 1, so -1 was unreachable, and no
spend branch let the value leave.

Retire requires the Config NFT burn and nothing else. The Config NFT only ever
sits at config.ak, so burning it spends the Config UTxO and runs its Retire
under update_auth. The authorization is inherited rather than restated."
```

---

### Task 6: The `RegistryUpdate` branch

**Files:**
- Modify: `onchain/validators/bitcoin/treasury.ak`

**Interfaces:**
- Consumes: `config_types.get_spos_registry_policy_id` (Task 2).
- Produces: the continuing-output helper `continuing_output`, reused by Task 7.

- [ ] **Step 1: Write the failing tests**

Append to the test section:

```aiken
//----------------------------------------------------------------------------
// Tests: RegistryUpdate
//----------------------------------------------------------------------------

// A registry token moves: the Register/Deregister marker RegistryUpdate needs.
fn t_registry_mint(qty: Int) -> assets.Value {
  assets.from_asset(t_registry_policy, "reg-root", qty)
}

fn t_registry_tx(
  d0: TreasuryDatum,
  d1: TreasuryDatum,
  mint: assets.Value,
  with_config_nft: Bool,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [t_input(d0)],
    reference_inputs: [t_config_ref_input(with_config_nft)],
    outputs: [t_output(d1)],
    mint: mint,
  }
}

fn t_registry_update(root: ByteArray) -> TreasurySpendRedeemer {
  RegistryUpdate {
    new_bifrost_identity_root: root,
    config_ref_input_index: 0,
  }
}

// spec [TSY-15]: only bifrost_identity_root changes.
test spend_registry_update_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(d0, t_registry_update(t_root1), t_registry_tx(d0, d1, t_registry_mint(1), True))
}

// A Deregister burns instead of minting. spec [TSY-13] sums the quantity, so a
// burn is just as good a marker as a mint.
test spend_registry_update_accepts_registry_burn() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(d0, t_registry_update(t_root1), t_registry_tx(d0, d1, t_registry_mint(-1), True))
}

// spec [TSY-15]: this branch must not rotate the key. Key rotation is UpdateY,
// and it is the only path with a signature check.
test spend_registry_update_rejects_key_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  t_spend(d0, t_registry_update(t_root1), t_registry_tx(d0, d1, t_registry_mint(1), True))
}

// spec [TSY-13]: without a registry token moving, anyone could rewrite the
// identity root.
test spend_registry_update_rejects_no_registry_mint() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(d0, t_registry_update(t_root1), t_registry_tx(d0, d1, assets.zero, True))
}

// spec [TSY-12]: the reference input must be the real Config UTxO. Without the
// NFT check an attacker supplies their own datum naming a policy they control.
test spend_registry_update_rejects_unauthenticated_config() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  t_spend(d0, t_registry_update(t_root1), t_registry_tx(d0, d1, t_registry_mint(1), False))
}

// spec [TSY-14]: the value must carry over untouched.
test spend_registry_update_rejects_value_drift() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let drained =
    Output { ..t_output(d1), value: assets.from_lovelace(1_000_000) }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_config_ref_input(True)],
      outputs: [drained],
      mint: t_registry_mint(1),
    }
  t_spend(d0, t_registry_update(t_root1), tx)
}

// spec [TSY-14]: and the UTxO must stay at this script.
test spend_registry_update_rejects_moved_output() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let moved =
    Output {
      ..t_output(d1),
      address: Address {
        payment_credential: Script(
          #"ff111111111111111111111111111111111111111111111111111111",
        ),
        stake_credential: None,
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      reference_inputs: [t_config_ref_input(True)],
      outputs: [moved],
      mint: t_registry_mint(1),
    }
  t_spend(d0, t_registry_update(t_root1), tx)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `aiken check -m "bitcoin/treasury"`

Expected: `spend_registry_update_happy` and
`spend_registry_update_accepts_registry_burn` FAIL, because the branch returns
`False`.

- [ ] **Step 3: Implement the branch and the shared helper**

Add above the validator:

```aiken
// spec [TSY-14]: the single continuing output at this script, with its address
// and its whole value unchanged. The NFT rides along inside the value equality,
// so no separate NFT check is needed on the output.
//
// Every branch that keeps the UTxO alive goes through here, which is what makes
// the field-permission matrix enforceable: each branch then rewrites the datum
// with a record-update spread off the spent datum, so any field it does not
// name is preserved verbatim.
fn continuing_output(
  self: Transaction,
  own_hash: ByteArray,
  own_input: Input,
) -> Output {
  expect [out] =
    list.filter(
      self.outputs,
      fn(output) { output.address.payment_credential == Script(own_hash) },
    )
  expect out.address == own_input.output.address
  expect out.value == own_input.output.value
  out
}

// The Config datum's raw fields, authenticated by the parameterized NFT.
// spec [TSY-2]: located by redeemer index, never by scanning reference_inputs.
// A scan costs O(reference_inputs), and a scan that finds nothing picks a wrong
// UTxO instead of failing. peg-in.ak states the same rule for the singleton.
fn config_fields_at(
  self: Transaction,
  config_policy_id: PolicyId,
  index: Int,
) -> List<Data> {
  utils.get_config_as_data_list(
    utils.safe_list_at(self.reference_inputs, index),
    config_policy_id,
    constants.config_nft_asset_name,
  )
}
```

Replace the `RegistryUpdate { .. } -> False` arm with:

```aiken
      RegistryUpdate { new_bifrost_identity_root, config_ref_input_index } -> {
        // spec [TSY-12]
        let config_fields =
          config_fields_at(self, config_policy_id, config_ref_input_index)
        let continued = continuing_output(self, own_hash, own_input)
        and {
          // spec [TSY-13]: a Register mints one membership token and a
          // Deregister burns one, so a non-zero sum is the marker. The registry
          // policy is the authority here; this branch only checks that it ran.
          utils.quantity_of_policy_id(
            self.mint,
            config_types.get_spos_registry_policy_id(config_fields),
          ) != 0,
          // spec [TSY-15]: the spread preserves current_spos_frost_key, so key
          // rotation cannot ride along on a registration.
          continued.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              bifrost_identity_root: new_bifrost_identity_root,
            },
          ),
        }
      }
```

Rename `_in_datum` back to `in_datum` in the prologue.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `aiken check -m "bitcoin/treasury"`

Expected: 24 tests pass.

- [ ] **Step 5: Commit**

```bash
git add onchain/validators/bitcoin/treasury.ak
git commit -m "feat(onchain): RegistryUpdate reads the registry policy from Config

The registry policy id was a compile parameter of this script, which made the
dependency a cycle: spos-registry.ak could then never take treasury_policy_id
as a parameter, and so could never pin the UTxO it updates. Reading it from the
Config datum breaks the cycle and costs one reference input.

The Config UTxO is authenticated by the parameterized NFT and found by redeemer
index, never by scanning reference inputs: a scan that finds nothing picks a
wrong UTxO instead of failing."
```

---

### Task 7: The `UpdateY` branch

**Files:**
- Modify: `onchain/validators/bitcoin/treasury.ak`

**Interfaces:**
- Consumes: `config_types.get_y_federation` (Task 2), `continuing_output` and
  `config_fields_at` (Task 6).
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to the test section:

```aiken
//----------------------------------------------------------------------------
// Tests: UpdateY
//----------------------------------------------------------------------------

fn t_update_y(
  new_key: ByteArray,
  epoch: Int,
  sig: ByteArray,
) -> TreasurySpendRedeemer {
  UpdateY {
    new_spos_frost_key: new_key,
    epoch: epoch,
    signature: sig,
    config_ref_input_index: 0,
  }
}

fn t_update_y_tx(
  d0: TreasuryDatum,
  d1: TreasuryDatum,
  with_config_nft: Bool,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [t_input(d0)],
    reference_inputs: [t_config_ref_input(with_config_nft)],
    outputs: [t_output(d1)],
  }
}

// spec [TSY-18]: the outgoing key authorizes its own succession.
test spend_update_y_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_new_key, t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [UY-5]: the federation signs the SAME message under the Config's
// y_federation, and the rotation passes without the outgoing roster. This
// standing co-authority is the whole dead-roster recovery, and [UY-6] is
// withdrawn, so the named key is arbitrary.
test spend_update_y_federation_signed() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_new_key, t_updatey_epoch, t_updatey_fed_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-18]: the epoch is inside the signed message.
test spend_update_y_rejects_wrong_epoch() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_new_key, t_updatey_epoch + 1, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-18]: a signature by a key that is neither the outgoing one nor the
// federation is worthless.
test spend_update_y_rejects_wrong_signer() fail {
  let d0 = t_datum(t_root0, t_new_key)
  let d1 = t_datum(t_root0, t_cur_key)
  t_spend(
    d0,
    t_update_y(t_cur_key, t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-17]: only the key changes on this branch.
test spend_update_y_rejects_extra_field_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  t_spend(
    d0,
    t_update_y(t_new_key, t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-16]: a short key would be unusable and unrecoverable.
test spend_update_y_rejects_short_key() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, #"abab")
  t_spend(
    d0,
    t_update_y(#"abab", t_updatey_epoch, t_updatey_sig),
    t_update_y_tx(d0, d1, True),
  )
}

// spec [TSY-12]: a forged Config reference input names a y_federation the
// attacker controls, which would make [UY-5] a free rotation for anyone.
test spend_update_y_rejects_unauthenticated_config() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  t_spend(
    d0,
    t_update_y(t_new_key, t_updatey_epoch, t_updatey_fed_sig),
    t_update_y_tx(d0, d1, False),
  )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `aiken check -m "bitcoin/treasury"`

Expected: `spend_update_y_happy` and `spend_update_y_federation_signed` FAIL,
because the branch returns `False`.

- [ ] **Step 3: Implement the branch**

Replace the `UpdateY { .. } -> False` arm with:

```aiken
      UpdateY { new_spos_frost_key, epoch, signature, config_ref_input_index } -> {
        // spec [TSY-12], [UY-5]: y_federation lives in the Config datum now.
        let config_fields =
          config_fields_at(self, config_policy_id, config_ref_input_index)
        let y_federation = config_types.get_y_federation(config_fields)
        let continued = continuing_output(self, own_hash, own_input)
        let msg =
          rotation_sig_msg(
            "bifrost-update-y",
            own_ref,
            epoch,
            new_spos_frost_key,
          )
        and {
          // spec [TSY-16]: a 32-byte x-only point. Point validity is the
          // roster's own problem — a bad point can only harm the roster that
          // signed for it.
          bytearray.length(new_spos_frost_key) == 32,
          // spec [TSY-17]
          continued.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              current_spos_frost_key: new_spos_frost_key,
            },
          ),
          // spec [TSY-18]. Two signers, either alone:
          //  - the OUTGOING key authorizes its own succession. In Phase 1 the
          //    spent datum holds Y_federation, so the federation signs the
          //    first rotation; after that each roster hands off to the next.
          //  - spec [UY-5]: OR the federation, under the Config's
          //    y_federation. That standing co-authority is the dead-roster
          //    recovery, and it replaces the withdrawn FederationReset branch.
          // Submission is permissionless: the signature IS the authorization,
          // and the message commits to the spent outpoint, so it cannot be
          // replayed.
          or {
            crypto.verify_schnorr_signature(
              in_datum.current_spos_frost_key,
              msg,
              signature,
            ),
            crypto.verify_schnorr_signature(y_federation, msg, signature),
          },
        }
      }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `aiken check -m "bitcoin/treasury"`

Expected: 31 tests pass.

- [ ] **Step 5: Run the whole suite**

Run: `aiken check`

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add onchain/validators/bitcoin/treasury.ak
git commit -m "feat(onchain): Update-Y takes y_federation from the Config datum

The federation key was a TreasuryDatum field that nothing could ever rotate,
while the field-permission matrix promised a federation-key rotation. Reading it
from Config makes that rotation an ordinary governance Update, and the [UY-5]
co-authority keeps working unchanged.

rotation_sig_msg is untouched, so the existing BIP340 vectors verify as-is and
heimdall's shared-vector test still pins both sides to the same message.

Governance can now install a y_federation and then sign a rotation under it.
That widens no boundary — update_auth can already rewrite every script hash a
reader resolves — but it is recorded in the spec's trust model section."
```

---

### Task 8: `spos-registry.ak` pins the Treasury state UTxO

**Files:**
- Modify: `onchain/validators/bitcoin/spos-registry.ak`

**Interfaces:**
- Consumes: `utils.treasury_state_pinned` (Task 1).
- Produces: `validator spo_registry(bootstrap_tx_id, bootstrap_output_index, treasury_policy_id)`.

This file has no tests today. The tests below call the private
`treasury_state_transition_ok` directly, which is legal because they live in the
same module. That avoids building a full linked-list fixture with real Ed25519
and Schnorr signatures and an MPF proof, none of which this task changes.

- [ ] **Step 1: Write the failing tests**

Append to `onchain/validators/bitcoin/spos-registry.ak`:

```aiken
//----------------------------------------------------------------------------
// Tests: the Treasury state pin
//
// spec [REG-6], [REG-7], [REG-8]. Before the pin existed, treasury_state_
// transition_ok took the treasury input and output from redeemer indexes and
// checked nothing but the datum transition. A registrant could point those
// indexes at a wallet UTxO carrying a TreasuryDatum-shaped datum, satisfy the
// [REG-5] absence proof against a trie it chose, and register a duplicate
// bifrost_id_pk while the real identity root stood still.
//----------------------------------------------------------------------------

const t_treasury_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

const t_frost_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

fn t_treasury_address() -> Address {
  Address {
    payment_credential: Script(t_treasury_policy),
    stake_credential: None,
  }
}

fn t_treasury_value(with_nft: Bool) -> Value {
  let base = assets.from_lovelace(2_000_000)
  if with_nft {
    base
      |> assets.add(
          t_treasury_policy,
          constants.treasury_info_nft_asset_name,
          1,
        )
  } else {
    base
  }
}

fn t_treasury_output(
  root: ByteArray,
  key: ByteArray,
  with_nft: Bool,
  address: Address,
) -> Output {
  Output {
    address,
    value: t_treasury_value(with_nft),
    datum: InlineDatum(
      TreasuryDatum {
        bifrost_identity_root: root,
        current_spos_frost_key: key,
      },
    ),
    reference_script: None,
  }
}

fn t_treasury_input(root: ByteArray, with_nft: Bool) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4444444444444444444444444444444444444444444444444444444444444444",
      output_index: 0,
    },
    output: t_treasury_output(root, t_frost_key, with_nft, t_treasury_address()),
  }
}

fn t_transition_tx(treasury_input: Input, treasury_output: Output) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [treasury_input],
    outputs: [treasury_output],
  }
}

test treasury_transition_happy() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, True, t_treasury_address()),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-6]: the decoy attack. A datum-shaped wallet UTxO is not the
// Treasury state UTxO.
test treasury_transition_rejects_decoy_input() fail {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, False),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-7]: the NFT must continue.
test treasury_transition_rejects_output_without_nft() fail {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-8]: and it must stay at treasury.ak.
test treasury_transition_rejects_moved_output() fail {
  let elsewhere =
    Address {
      payment_credential: Script(
        #"ff111111111111111111111111111111111111111111111111111111",
      ),
      stake_credential: None,
    }
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, True, elsewhere),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// The datum rule the pin does not replace: the registry may move the identity
// root and nothing else.
test treasury_transition_rejects_key_change() fail {
  let other_key =
    #"abababababababababababababababababababababababababababababababab"
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, other_key, True, t_treasury_address()),
    )
  treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}
```

Add the imports these fixtures need to the top of the file:

```aiken
use bifrost/constants
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, Value, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
  placeholder,
}
```

`Address`, `Value` and `placeholder` are the additions; the rest are already
imported.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `aiken check -m "spos-registry"`

Expected: compile error, because `treasury_state_transition_ok` takes four
arguments today and the tests pass five.

- [ ] **Step 3: Add the pin**

Change `treasury_state_transition_ok` to take the policy id and apply the
helper:

```aiken
// spec [REG-6], [REG-7], [REG-8]: the treasury input and output are located by
// redeemer index, so they MUST be authenticated before their datums are
// trusted. Without this, the indexes may name any UTxO with a datum of the
// right shape, and the [REG-5] absence proof then runs against a trie the
// registrant chose.
fn treasury_state_transition_ok(
  self: Transaction,
  treasury_input_index: Int,
  treasury_output_index: Int,
  new_bifrost_identity_root: ByteArray,
  treasury_policy_id: PolicyId,
) -> Bool {
  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_output = utils.safe_list_at(self.outputs, treasury_output_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)
  let treasury_output_datum = get_treasury_datum(treasury_output)

  and {
    utils.treasury_state_pinned(
      treasury_input,
      treasury_output,
      treasury_policy_id,
    ),
    treasury_output_datum == updated_treasury_datum(
      treasury_input_datum,
      new_bifrost_identity_root,
    ),
  }
}
```

Thread the parameter through both callers. `validate_registration` and
`validate_deregistration` each gain a `treasury_policy_id: PolicyId` argument
and pass it to `treasury_state_transition_ok`. Declare the validator as:

```aiken
validator spo_registry(
  bootstrap_tx_id: ByteArray,
  bootstrap_output_index: Int,
  treasury_policy_id: PolicyId,
) {
```

and pass `treasury_policy_id` at the two call sites inside the `mint` handler:

```aiken
      SposRegistryMintRedeemer.Register { .. } ->
        validate_registration(redeemer, policy_id, self, treasury_policy_id)
      SposRegistryMintRedeemer.Deregister { .. } ->
        validate_deregistration(redeemer, policy_id, self, treasury_policy_id)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `aiken check -m "spos-registry"`

Expected: 5 tests pass.

- [ ] **Step 5: Run the whole suite**

Run: `aiken check`

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add onchain/validators/bitcoin/spos-registry.ak
git commit -m "fix(onchain): authenticate the Treasury state UTxO before trusting it

treasury_state_transition_ok took the treasury input and output from redeemer
indexes and checked nothing but the datum transition. No NFT check and no
address check on either side.

A registrant could add a wallet UTxO carrying a TreasuryDatum-shaped datum,
point both indexes at it and its change output, and satisfy the [REG-5] absence
proof against a trie it picked. The registry list then gained a real membership
token while the real identity root never moved, which is exactly the global
uniqueness of bifrost_id_pk that [REG-5] and [DRG-4] exist to enforce.

The pin is a compile parameter, now that treasury_info no longer takes the
registry policy id and the dependency is a chain instead of a cycle."
```

---

### Task 9: Update the technical documentation

**Files:**
- Modify: `onchain/../documentation/technical_documentation.md`

**Interfaces:**
- Consumes: the final state of every earlier task.
- Produces: a spec that matches the code.

- [ ] **Step 1: Rewrite §Config datum**

Replace the field table (around line 849) with the 12-field layout and the
8-field `ConfigParams` layout from the design spec §D5. Add [CFG-4] through
[CFG-7] to the check list. Mark `treasury_info_asset_name` WITHDRAWN; do not
delete the row, and do not renumber any surviving [CFG-*] ID.

- [ ] **Step 2: Rewrite §Treasury state UTxO**

At line 1041 onward: the datum table becomes two rows. The "minted exactly
once" paragraph becomes true and cites the one-shot outpoint and the `"BFRTRY"`
constant. The field-permission matrix loses its `y_federation` and
`federation_csv_blocks` rows and gains a Retire row. Add the [TSY-1] to [TSY-22]
list.

- [ ] **Step 3: Update §Update-Y**

Revise [UY-5] to say `treasury.ak` reads `y_federation` from the Config
reference input. Leave [UY-6], [UY-7] and [UY-8] WITHDRAWN. Update the
Implementation status note: rev 5.5 replaces the `registry_policy_id` parameter
with the Config read, and [PRE-1] is revised rather than withdrawn.

- [ ] **Step 4: Update §SPO Registration**

Add [REG-6], [REG-7], [REG-8] and [DRG-5]. Leave [REG-5] and [DRG-4] worded as
they are, and add an Implementation status note saying they became enforceable
against the real Treasury state UTxO in rev 5.5.

- [ ] **Step 5: Update §Parameter registry**

The "Treasury state NFT identity" row (line 1450) says **validator parameter**
and was false. It is true now: name the parameter as `spo_registry`'s third
argument. Add a row for the Config NFT asset name, sourced as a protocol
constant per [CFG-7].

- [ ] **Step 6: Add [FED-4]**

In §Treasury state UTxO, give the existing unnumbered sweep-or-refund rule the
ID [FED-4], and note that a Config Update is its trigger now.

- [ ] **Step 7: Add the trust model note**

In §Trust model, record that governance can install a `y_federation` and then
sign an Update-Y under it. State that this widens no boundary, because
`update_auth` can already rewrite every script hash a reader resolves.

- [ ] **Step 8: Verify no ID was renumbered**

Run:

Tasks 1 to 8 do not touch this file, so the committed `HEAD` version is still
the pre-refactor one. Run this BEFORE committing Step 9:

```bash
grep -oE '\[[A-Z]{2,4}-[0-9]+\]' documentation/technical_documentation.md \
  | sort -u > /tmp/ids-after.txt
git show HEAD:documentation/technical_documentation.md \
  | grep -oE '\[[A-Z]{2,4}-[0-9]+\]' | sort -u > /tmp/ids-before.txt
comm -23 /tmp/ids-before.txt /tmp/ids-after.txt
```

Expected: empty output. Any ID printed has been deleted rather than marked
WITHDRAWN. Restore it.

- [ ] **Step 9: Commit**

```bash
git add documentation/technical_documentation.md
git commit -m "docs(spec): rev 5.5, the Treasury state UTxO has an enforceable identity

Two claims in this document were false and are now true. The Treasury state NFT
is minted exactly once, because the one-shot outpoint is baked into its policy
id. Its identity is a validator parameter, because spo_registry takes it as one.

The Config datum table is the twelve-field rev-5.5 layout, TreasuryDatum is two
fields, and [REG-6] to [REG-8] give the registry the pin it never had."
```

---

## Out of scope

heimdall changes are listed in the design spec §Off-chain: heimdall. They land
in `~/projects/lantr/heimdall`, in their own commits, after this plan is green.
Nothing in this plan may be committed inside the submodule checkout.

Binocular needs no change.
