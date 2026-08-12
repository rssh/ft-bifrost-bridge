use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use aiken_design_patterns/linked_list
use bifrost/types/spos_registry.{
  ListRootData, RegistrationListDatum, RegistrationNodeData,
  SposRegistryMintRedeemer, SposRegistrySpendRedeemer,
}
use bifrost/constants
use bifrost/types/treasury.{TreasuryDatum}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, Value, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
  placeholder,
}

const registration_root_key = "reg-root"

const registration_node_key_prefix = ""

const registration_node_key_prefix_length = 0

const registration_domain_separator = "bifrost-spo"

const revocation_domain_separator = "bifrost-revoke"

fn registration_message(
  pool_id: ByteArray,
  bifrost_id_pk: ByteArray,
  bifrost_url: ByteArray,
) -> ByteArray {
  bytearray.concat(
    registration_domain_separator,
    bytearray.concat(pool_id, bytearray.concat(bifrost_id_pk, bifrost_url)),
  )
}

fn revocation_message(pool_id: ByteArray) -> ByteArray {
  bytearray.concat(revocation_domain_separator, pool_id)
}

fn get_treasury_datum(output: Output) -> TreasuryDatum {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: TreasuryDatum = raw_datum
  datum
}

fn get_registration_node_data(output: Output) -> RegistrationNodeData {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: RegistrationListDatum = raw_datum
  when datum.data is {
    linked_list.Node { data } -> data
    linked_list.Root { .. } -> fail @"Registration output must be a node"
  }
}

fn validate_registration_anchor_data(
  anchor_key: Option<ByteArray>,
  anchor_data: Data,
) -> Bool {
  when anchor_key is {
    None -> {
      expect _: ListRootData = anchor_data
      True
    }
    Some(_) -> {
      expect _: RegistrationNodeData = anchor_data
      True
    }
  }
}

fn validate_root_data(_root_lovelace: Int, root_data: Data) -> Bool {
  validate_registration_anchor_data(None, root_data)
}

fn validate_bootstrap_root(
  outputs: List<Output>,
  tx_mint: Value,
  policy_id: PolicyId,
  root_key: ByteArray,
) -> Bool {
  let root_output =
    utils.find_singleton_asset_output_at_script(
      outputs,
      policy_id,
      policy_id,
      root_key,
    )

  linked_list.init(True, root_output, tx_mint, validate_root_data)
    |> linked_list.run_root_with(policy_id, root_key)
}

fn updated_treasury_datum(
  treasury_input_datum: TreasuryDatum,
  new_bifrost_identity_root: ByteArray,
) -> TreasuryDatum {
  // Registration/deregistration changes ONLY the identity root; the frost key
  // and the federation fields are preserved (record-update spread — matches
  // treasury.ak's RegistryUpdate branch, and stays correct across datum shape
  // changes).
  TreasuryDatum {
    ..treasury_input_datum,
    bifrost_identity_root: new_bifrost_identity_root,
  }
}

// spec [REG-6], [REG-7], [REG-8]: the treasury input and output are located by
// redeemer index, so they MUST be authenticated before their datums are
// trusted. Without the pin the indexes may name ANY UTxO carrying a datum of
// the right shape, and the [REG-5] absence proof then runs against a trie the
// registrant chose: the registry list gains a real membership token while the
// real identity root never moves, defeating the global uniqueness of
// bifrost_id_pk that [REG-5] and [DRG-4] exist to enforce.
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

fn validate_bootstrap(
  self: Transaction,
  policy_id: PolicyId,
  bootstrap_ref: OutputReference,
) -> Bool {
  expect Some(_bootstrap_input) = find_input(self.inputs, bootstrap_ref)

  and {
    utils.quantity_of_policy_id(self.mint, policy_id) == 1,
    quantity_of(self.mint, policy_id, registration_root_key) == 1,
    validate_bootstrap_root(
      self.outputs,
      self.mint,
      policy_id,
      registration_root_key,
    ),
  }
}

fn validate_registration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
  treasury_policy_id: PolicyId,
) -> Bool {
  expect SposRegistryMintRedeemer.Register {
    cold_vkey,
    cold_sig,
    bifrost_sig,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_absence_proof,
  } = redeemer

  expect Pair(pool_id, 1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  let anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let new_registration_output =
    utils.find_singleton_asset_output_at_script(
      self.outputs,
      policy_id,
      policy_id,
      pool_id,
    )
  let RegistrationNodeData { bifrost_id_pk, bifrost_url } =
    get_registration_node_data(new_registration_output)

  let registration_linked_list_ok =
    linked_list.insert_ascending(
      anchor_input,
      continued_anchor_output,
      new_registration_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _new_node_lovelace,
        new_node_key,
        new_node_data,
        _new_node_link,
      ) {
        expect parsed_new_node_data: RegistrationNodeData = new_node_data

        let message =
          registration_message(
            new_node_key,
            parsed_new_node_data.bifrost_id_pk,
            parsed_new_node_data.bifrost_url,
          )

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          new_node_key == pool_id,
          parsed_new_node_data == RegistrationNodeData {
            bifrost_id_pk,
            bifrost_url,
          },
          crypto.blake2b_224(cold_vkey) == new_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
          crypto.verify_schnorr_signature(
            bifrost_id_pk,
            crypto.sha2_256(message),
            bifrost_sig,
          ),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.insert(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_absence_proof,
    )
      |> mpf.root

  and {
    registration_linked_list_ok,
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
      treasury_policy_id,
    ),
  }
}

fn validate_deregistration(
  redeemer: SposRegistryMintRedeemer,
  policy_id: PolicyId,
  self: Transaction,
  treasury_policy_id: PolicyId,
) -> Bool {
  expect SposRegistryMintRedeemer.Deregister {
    cold_vkey,
    cold_sig,
    registration_input_index,
    registration_anchor_input_index,
    registration_anchor_output_index,
    treasury_input_index,
    treasury_output_index,
    bifrost_identity_removal_proof,
  } = redeemer

  expect Pair(pool_id, -1) =
    utils.get_singleton_asset_with_policy(self.mint, policy_id)

  let registration_input =
    utils.safe_list_at(self.inputs, registration_input_index)
  let registration_anchor_input =
    utils.safe_list_at(self.inputs, registration_anchor_input_index)
  let continued_anchor_output =
    utils.safe_list_at(self.outputs, registration_anchor_output_index)
  let RegistrationNodeData { bifrost_id_pk, bifrost_url: _bifrost_url } =
    get_registration_node_data(registration_input.output)

  let deregistration_linked_list_ok =
    linked_list.remove(
      registration_anchor_input,
      registration_input,
      continued_anchor_output,
      self.mint,
      fn(
        anchor_lovelace_change,
        anchor_key,
        anchor_data,
        _removed_node_lovelace,
        removed_node_key,
        removed_node_data,
        _removed_node_link,
      ) {
        expect parsed_removed_node_data: RegistrationNodeData =
          removed_node_data
        let message = revocation_message(removed_node_key)

        and {
          validate_registration_anchor_data(anchor_key, anchor_data),
          anchor_lovelace_change == 0,
          removed_node_key == pool_id,
          parsed_removed_node_data.bifrost_id_pk == bifrost_id_pk,
          crypto.blake2b_224(cold_vkey) == removed_node_key,
          crypto.verify_ed25519_signature(cold_vkey, message, cold_sig),
        }
      },
    )
      |> linked_list.run_eval_with(
          policy_id,
          registration_root_key,
          registration_node_key_prefix,
          registration_node_key_prefix_length,
        )

  let treasury_input = utils.safe_list_at(self.inputs, treasury_input_index)
  let treasury_input_datum = get_treasury_datum(treasury_input.output)

  let updated_bifrost_identity_root =
    mpf.delete(
      mpf.from_root(treasury_input_datum.bifrost_identity_root),
      bifrost_id_pk,
      pool_id,
      bifrost_identity_removal_proof,
    )
      |> mpf.root

  and {
    deregistration_linked_list_ok,
    // spec [DRG-5]: [REG-6] to [REG-8] apply unchanged to Deregister.
    treasury_state_transition_ok(
      self,
      treasury_input_index,
      treasury_output_index,
      updated_bifrost_identity_root,
      treasury_policy_id,
    ),
  }
}

// spec [REG-6]: treasury_policy_id is a COMPILE PARAMETER, and it can be one
// only because rev 5.5 broke the cycle. treasury_info used to take
// registry_policy_id, which made the treasury policy a function of this one, so
// this parameter would have been self-referential. treasury.ak now reads the
// registry policy from the Config datum instead.
validator spo_registry(
  bootstrap_tx_id: ByteArray,
  bootstrap_output_index: Int,
  treasury_policy_id: PolicyId,
) {
  mint(
    redeemer: SposRegistryMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    let bootstrap_ref = OutputReference(bootstrap_tx_id, bootstrap_output_index)

    when redeemer is {
      SposRegistryMintRedeemer.Bootstrap ->
        validate_bootstrap(self, policy_id, bootstrap_ref)
      SposRegistryMintRedeemer.Register { .. } ->
        validate_registration(redeemer, policy_id, self, treasury_policy_id)
      SposRegistryMintRedeemer.Deregister { .. } ->
        validate_deregistration(redeemer, policy_id, self, treasury_policy_id)
    }
  }

  spend(
    _datum: Option<Data>,
    _redeemer: SposRegistrySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential

    utils.quantity_of_policy_id(self.mint, own_hash) != 0
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests: the Treasury state pin
//
// spec [REG-6], [REG-7], [REG-8]. Before the pin existed,
// treasury_state_transition_ok took the treasury input and output from redeemer
// indexes and checked nothing but the datum transition. A registrant could
// point those indexes at a wallet UTxO carrying a TreasuryDatum-shaped datum,
// satisfy the [REG-5] absence proof against a trie it chose, and register a
// duplicate bifrost_id_pk while the real identity root stood still.
//
// These call treasury_state_transition_ok directly. A full Register fixture
// would need a linked-list anchor, an Ed25519 vector, a BIP340 vector and an
// MPF proof, none of which this change touches.
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
      |> assets.add(t_treasury_policy, constants.treasury_info_nft_asset_name, 1)
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
    address: address,
    value: t_treasury_value(with_nft),
    datum: InlineDatum(
      TreasuryDatum { bifrost_identity_root: root, current_spos_frost_key: key },
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

fn t_transition_tx(
  treasury_input: Input,
  treasury_output: Output,
) -> Transaction {
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
test treasury_transition_rejects_decoy_input() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, False),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-7]: the NFT must continue into the output.
test treasury_transition_rejects_output_without_nft() {
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, t_frost_key, False, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// spec [REG-8]: and it must stay at treasury.ak.
test treasury_transition_rejects_moved_output() {
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
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}

// The datum rule the pin does not replace: the registry may move the identity
// root and nothing else.
test treasury_transition_rejects_key_change() {
  let other_key =
    #"abababababababababababababababababababababababababababababababab"
  let tx =
    t_transition_tx(
      t_treasury_input(t_root0, True),
      t_treasury_output(t_root1, other_key, True, t_treasury_address()),
    )
  !treasury_state_transition_ok(tx, 0, 0, t_root1, t_treasury_policy)
}
