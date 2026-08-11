use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use bifrost/types/completed_peg_ins.{CompletedPegInsTrieDatum}
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
/// The completed-peg-ins trie from a CPI-trie UTxO's inline datum.
///
/// A TYPED decode, not a blind field-0 read. The rule is the one [LIB-1]
/// states for the singleton and [CTM-27] states for Confirm, and it applies to
/// every datum in this tree EXCEPT `ConfigDatum`: only the Config UTxO must
/// stay append-extensible, because every contract is parameterized by its NFT
/// and so the Config alone cannot be swapped. Every other datum sits behind a
/// Config-updatable script hash, so pinning its exact shape costs nothing —
/// a datum change ships as a new validator plus a Config Update.
///
/// The blind form this replaces (`unconstr_fields |> head_list |> un_b_data`)
/// accepted ANY constructor tag and ANY arity. That is not academic here: the
/// CONTINUING output's datum is chosen by whoever builds the completion, so
/// `Constr 5 [root, junk]` would have been accepted at the trie address and
/// every stricter reader downstream — on-chain or off — would then fail on a
/// datum the protocol never describes.
pub fn get_mpf_from_output(output: Output) -> mpf.MerklePatriciaForestry {
  expect InlineDatum(datum) = output.datum
  expect trie: CompletedPegInsTrieDatum = datum
  mpf.from_root(trie.root)
}

pub fn bitcoin_hash(bytes: ByteArray) -> ByteArray {
  crypto.sha2_256(crypto.sha2_256(bytes))
}
