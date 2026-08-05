use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{Script}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  outputRef |> builtin.serialise_data |> crypto.sha2_256
}

pub fn safe_list_at(self: List<a>, index: Int) -> a {
  expect index >= 0
  do_list_at(self, index)
}

fn do_list_at(self: List<a>, index: Int) -> a {
  if index == 0 {
    builtin.head_list(self)
  } else {
    do_list_at(builtin.tail_list(self), index - 1)
  }
}

pub fn get_config_as_data_list(
  configRefInput: Input,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  expect
    quantity_of(
      configRefInput.output.value,
      configNFTPolicyId,
      configNFTAssetName,
    ) > 0
  expect InlineDatum(outputDatum) = configRefInput.output.datum
  builtin.unconstr_fields(outputDatum)
}

/// Returns the quantity of all tokens with the policyId
pub fn quantity_of_policy_id(value: Value, policyId: PolicyId) {
  dict.foldl(tokens(value, policyId), 0, fn(_k, v, result) { v + result })
}

// Used to retrieve a singleton asset from a value with a specific policy id
pub fn get_singleton_asset_with_policy(
  value: Value,
  policy_id: PolicyId,
) -> Pair<AssetName, Int> {
  expect [p] =
    value
      |> assets.tokens(policy_id)
      //return dict of policy id to asset name and quantity
      |> dict.to_pairs

  p
}

pub fn find_singleton_asset_output_at_script(
  outputs: List<Output>,
  script_hash: ByteArray,
  policy_id: PolicyId,
  asset_name: AssetName,
) -> Output {
  expect Some(output) =
    list.find(
      outputs,
      fn(output) {
        output.address.payment_credential == Script(script_hash) && quantity_of(
          output.value,
          policy_id,
          asset_name,
        ) == 1
      },
    )

  output
}

//Expects the merkle root to be the first field of the InlineDatum
pub fn get_mpf_from_output(output: Output) -> mpf.MerklePatriciaForestry {
  expect InlineDatum(datum) = output.datum
  datum
    |> builtin.unconstr_fields
    |> builtin.head_list
    |> builtin.un_b_data
    |> mpf.from_root
}

pub fn bitcoin_hash(bytes: ByteArray) -> ByteArray {
  crypto.sha2_256(crypto.sha2_256(bytes))
}
