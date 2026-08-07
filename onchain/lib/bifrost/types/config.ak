use aiken/builtin
use bifrost/types/general.{AuthorizationMethod, CardanoSignature}
use bifrost/utils.{safe_list_at}
use cardano/assets.{PolicyId}

pub type ConfigSpendRedeemer {
  Update
  Retire
}

//The rev-5.4 seven-field Config datum (spec §Config datum). update_auth comes
//first, because it is the field that governs every other one.
//
//Removed from the rev-5.1 layout (spec §Config datum, "Rev 5.1's fields ...
//are all GONE"):
//- bridged_token_asset_name: now the [CFG-1] constant "fSAT" in
//  bifrost/constants.
//- peg_in_close_verifier_script_hash: the SPI trie removes the close
//  verifier for good; both close reasons become MPF proofs in peg-in.ak.
//- both legit_treasury_movement_* hashes: vestigial, dummy on the deployed
//  instance.
//- min_stake: it was off-chain-only (the heimdall R2 registration gate had
//  no on-chain reader), so it leaves the datum with the other unread fields.
//- initial_btc_treasury_utxo: [BSS-4] takes the anchor from the bootstrap
//  redeemer.
//- leader_reward: no on-chain reader in this tree.
pub type ConfigDatum {
  //Authority allowed to Update/Retire the config UTxO. None = frozen.
  update_auth: Option<AuthorizationMethod>,
  //fBTC policy id
  bridged_token_policy: PolicyId,
  //CPI trie NFT policy
  completed_peg_ins_policy: PolicyId,
  //Bridge state singleton NFT policy
  bridge_state_policy: PolicyId,
  peg_in_script_hash: ByteArray,
  peg_out_script_hash: ByteArray,
  //Operational parameters, one nested record so governance can replace it
  //wholesale without renumbering its neighbours.
  params: ConfigParams,
}

//The tunable operational parameters (spec §Operational parameters).
pub type ConfigParams {
  //Exact miner fee rate (sat/vB) for deterministic TM construction.
  fee_rate_sat_per_vb: Int,
  //Floor (satoshi) for the per-peg-out protocol fee; the effective fee pins
  //into each PegOutDatum at lock time.
  per_pegout_fee: Int,
  //Minimum bridged-token amount (satoshi) a PegOut may lock.
  min_peg_out_fbtc: Int,
  //Epoch/TM schedule. Off-chain readers only.
  schedule: ScheduleParams,
}

//The tunable protocol schedule, E-relative slot values (spec §TM batches and
//the protocol schedule; constraints there — notably stability_window = 3k/f,
//tunable only upward). Off-chain readers only.
pub type ScheduleParams {
  dkg_r1_deadline: Int,
  dkg_r2_deadline: Int,
  update_y_deadline: Int,
  tm_batch_interval: Int,
  sign_r1_window: Int,
  sign_r2_window: Int,
  leader_slot_t: Int,
  tm_recovery_window: Int,
  final_tm_cutoff: Int,
  stability_window: Int,
}

//----------------------------------------------------------------------------
// Positional getters over the raw config fields list, as returned by
// utils.get_config_as_data_list. Field indexes live ONLY here.
//
// Readers deliberately do NOT cast the datum to ConfigDatum. An
// `expect datum: ConfigDatum` compiles to a full runtime shape check that
// enforces the constructor tag, the exact field count, and every field's
// type (verified by experiment on aiken v1.1.19: an appended extra field, a
// retyped field, or a changed constructor tag all make the cast fail). Since
// several readers are immutable once deployed (notably the fBTC minting
// policy), a full cast would make any future ConfigDatum shape change
// impossible without breaking them. The getters validate only the fields a
// reader actually accesses, so fields can be appended (and unread fields
// changed) without redeploying existing readers. The trade-off: existing
// field positions and types are a frozen contract; evolve the datum by
// appending only.
//
// Keep the getters in the exact order of the ConfigDatum definition above;
// the config_getters_match_datum_fields test pins each index to its record
// field.
//----------------------------------------------------------------------------

pub fn get_update_auth(
  config_fields: List<Data>,
) -> Option<AuthorizationMethod> {
  expect update_auth: Option<AuthorizationMethod> =
    safe_list_at(config_fields, 0)
  update_auth
}

pub fn get_bridged_token_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 1))
}

pub fn get_completed_peg_ins_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 2))
}

pub fn get_bridge_state_policy(config_fields: List<Data>) -> PolicyId {
  builtin.un_b_data(safe_list_at(config_fields, 3))
}

pub fn get_peg_in_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 4))
}

pub fn get_peg_out_script_hash(config_fields: List<Data>) -> ByteArray {
  builtin.un_b_data(safe_list_at(config_fields, 5))
}

//The nested params record (ConfigDatum field 6) as its raw fields list.
//Indexes inside it live only in the getters below.
fn get_params_fields(config_fields: List<Data>) -> List<Data> {
  builtin.unconstr_fields(safe_list_at(config_fields, 6))
}

pub fn get_fee_rate_sat_per_vb(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 0))
}

pub fn get_per_pegout_fee(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 1))
}

pub fn get_min_peg_out_fbtc(config_fields: List<Data>) -> Int {
  builtin.un_i_data(safe_list_at(get_params_fields(config_fields), 2))
}

//Off-chain/test use only. Unlike the other getters this is a FULL cast of
//the nested record, so any on-chain reader adopting it would freeze
//ScheduleParams' inner shape (defeating the point of nesting it). No Aiken
//validator reads the schedule; keep it that way.
pub fn get_schedule(config_fields: List<Data>) -> ScheduleParams {
  expect schedule: ScheduleParams =
    safe_list_at(get_params_fields(config_fields), 3)
  schedule
}

//Pins every getter index to its ConfigDatum record field. The fixture is a
//real ConfigDatum record, serialized with builtin.unconstr_fields, and each
//getter's result is compared against the record field it must read. Every
//field carries a distinct value, so a reordering of the record definition
//relative to the getter indexes fails this test even when the swapped
//fields share a type.
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
      fee_rate_sat_per_vb: 12,
      per_pegout_fee: 13,
      min_peg_out_fbtc: 14,
      schedule,
    }
  let datum =
    ConfigDatum {
      update_auth: Some(CardanoSignature { hash: #"aa10" }),
      bridged_token_policy: #"aa01",
      completed_peg_ins_policy: #"aa02",
      bridge_state_policy: #"aa03",
      peg_in_script_hash: #"aa04",
      peg_out_script_hash: #"aa05",
      params,
    }
  let datum_data: Data = datum
  let fields = builtin.unconstr_fields(datum_data)
  and {
    //index 0
    get_update_auth(fields) == datum.update_auth,
    //index 1
    get_bridged_token_policy(fields) == datum.bridged_token_policy,
    //index 2
    get_completed_peg_ins_policy(fields) == datum.completed_peg_ins_policy,
    //index 3
    get_bridge_state_policy(fields) == datum.bridge_state_policy,
    //index 4
    get_peg_in_script_hash(fields) == datum.peg_in_script_hash,
    //index 5
    get_peg_out_script_hash(fields) == datum.peg_out_script_hash,
    //index 6, nested params record
    get_fee_rate_sat_per_vb(fields) == params.fee_rate_sat_per_vb,
    get_per_pegout_fee(fields) == params.per_pegout_fee,
    get_min_peg_out_fbtc(fields) == params.min_peg_out_fbtc,
    get_schedule(fields) == params.schedule,
  }
}
