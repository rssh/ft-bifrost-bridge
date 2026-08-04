use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use bifrost/constants
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, Value, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
  placeholder,
}

pub type CompletedPegOutsMerkleTreeDatum {
  root: ByteArray,
}

//Constr tag of an inline TM datum: 0 = Unconfirmed, 1 = Confirmed. Raw-tag
//read only — deliberately NO field decode, so this validator never couples to
//the Scalus TmDatum arity (which has grown twice already: N7, N10b).
fn tm_datum_tag(output: Output) -> Option<Int> {
  when output.datum is {
    InlineDatum(d) -> {
      let Pair(tag, _fields) = builtin.un_constr_data(d)
      Some(tag)
    }
    _ -> None
  }
}

fn carries_tm_nft(value: Value, tm_nft_policy_id: ByteArray) -> Bool {
  quantity_of(value, tm_nft_policy_id, constants.btc_asset_name) == 1
}

validator completed_peg_outs_merkle_tree_validator(
  //The TM NFT policy = the binocular TreasuryMovementValidator script hash.
  //A direct parameter (not a config read): the TM hash is computable before
  //this script's, and the TM validator finds THIS policy via config field 3,
  //so there is no parameterization cycle.
  tm_nft_policy_id: ByteArray,
  one_shot_input_ref: OutputReference,
) {
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    let is_one_shot_spent =
      option.is_some(find_input(self.inputs, one_shot_input_ref))
    expect [trie_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )
    expect [Pair(minted_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    and {
      is_one_shot_spent,
      minted_asset_name == constants.completed_peg_outs_root_asset_name,
      trie_output.datum == InlineDatum(
        CompletedPegOutsMerkleTreeDatum {
          root: #"0000000000000000000000000000000000000000000000000000000000000000",
        },
      ),
      trie_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      },
    }
  }

  //Spendable only inside a TM Confirm transition: one input carries the TM NFT
  //with an Unconfirmed (tag 0) datum, one output carries it with a Confirmed
  //(tag 1) datum. Root correctness, address/value preservation of the trie
  //continuation, and the per-peg-out inserts are all enforced by the Scalus TM
  //validator in the same transaction (the same delegation-by-pairing the old
  //version used toward peg_out.ak).
  spend(
    _datumOpt: Option<Data>,
    _redeemer: Data,
    _own_ref: OutputReference,
    self: Transaction,
  ) {
    let tm_unconfirmed_spent =
      list.any(
        self.inputs,
        fn(input) {
          carries_tm_nft(input.output.value, tm_nft_policy_id) && tm_datum_tag(
            input.output,
          ) == Some(0)
        },
      )
    let tm_confirmed_produced =
      list.any(
        self.outputs,
        fn(output) {
          carries_tm_nft(output.value, tm_nft_policy_id) && tm_datum_tag(output) == Some(
            1,
          )
        },
      )
    and {
      tm_unconfirmed_spent,
      tm_confirmed_produced,
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_tm_policy: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const t_trie_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_tx0: ByteArray =
  #"0101010101010101010101010101010101010101010101010101010101010101"

const t_index0: Int = 0

const t_zero_root: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

fn t_one_shot_ref() -> OutputReference {
  OutputReference { transaction_id: t_tx0, output_index: t_index0 }
}

fn t_dummy_own_ref() -> OutputReference {
  OutputReference {
    transaction_id: #"2222222222222222222222222222222222222222222222222222222222222222",
    output_index: 0,
  }
}

fn t_one_shot_input() -> Input {
  Input {
    output_reference: t_one_shot_ref(),
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

//A TM UTxO carrying the TM NFT under `policy_id`, with a raw Constr `tag`
//datum. Only the tag is ever set: this validator never decodes fields, so
//the fixture deliberately doesn't mirror the real TmDatum shape either.
fn t_tm_output(policy_id: ByteArray, tag: Int) -> Output {
  Output {
    address: Address {
      payment_credential: Script(policy_id),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(policy_id, constants.btc_asset_name, 1),
    datum: InlineDatum(builtin.constr_data(tag, [])),
    reference_script: None,
  }
}

fn t_tm_input(policy_id: ByteArray, tag: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"9999999999999999999999999999999999999999999999999999999999999999",
      output_index: 0,
    },
    output: t_tm_output(policy_id, tag),
  }
}

fn t_trie_output(asset_name: ByteArray, root: ByteArray) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_trie_policy),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_trie_policy, asset_name, 1),
    datum: InlineDatum(CompletedPegOutsMerkleTreeDatum { root }),
    reference_script: None,
  }
}

fn t_spend(tx: Transaction) -> Bool {
  completed_peg_outs_merkle_tree_validator.spend(
    t_tm_policy,
    t_one_shot_ref(),
    None,
    Void,
    t_dummy_own_ref(),
    tx,
  )
}

fn t_mint(tx: Transaction) -> Bool {
  completed_peg_outs_merkle_tree_validator.mint(
    t_tm_policy,
    t_one_shot_ref(),
    Void,
    t_trie_policy,
    tx,
  )
}

//(a) Confirm transition: TM Unconfirmed (tag 0) in, TM Confirmed (tag 1) out.
test spend_confirm_transition_happy() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_tm_input(t_tm_policy, 0)],
      outputs: [t_tm_output(t_tm_policy, 1)],
    }
  t_spend(tx)
}

//(b) No TM input at all: nothing for the Confirm transition to pair against.
test spend_rejects_no_tm_input() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      outputs: [t_tm_output(t_tm_policy, 1)],
    }
  t_spend(tx)
}

//(c) The TM input is already Confirmed (tag 1): a GC/burn spend of the TM
//record, not a Confirm transition, so the trie must stay locked.
test spend_rejects_tm_input_already_confirmed() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_tm_input(t_tm_policy, 1)],
      outputs: [t_tm_output(t_tm_policy, 1)],
    }
  t_spend(tx)
}

//(d) The TM output never reaches Confirmed (tag 0 out): no Confirm happened.
test spend_rejects_output_not_confirmed() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_tm_input(t_tm_policy, 0)],
      outputs: [t_tm_output(t_tm_policy, 0)],
    }
  t_spend(tx)
}

//(e) The "TM" input/output carry the right tags but the wrong policy id: not
//an authentic TM NFT, so it cannot satisfy the Confirm-transition gate.
test spend_rejects_wrong_tm_policy() fail {
  let foreign_policy =
    #"ff777777777777777777777777777777777777777777777777777777"
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_tm_input(foreign_policy, 0)],
      outputs: [t_tm_output(foreign_policy, 1)],
    }
  t_spend(tx)
}

//(f) Bootstrap mint happy path.
test mint_bootstrap_happy_path() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [
        t_trie_output(constants.completed_peg_outs_root_asset_name, t_zero_root),
      ],
      mint: assets.from_asset(
        t_trie_policy,
        constants.completed_peg_outs_root_asset_name,
        1,
      ),
    }
  t_mint(tx)
}

//(g.1) Bootstrap rejects a mint under any asset name other than "CPO".
test mint_bootstrap_rejects_wrong_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_trie_output("WRONG", t_zero_root)],
      mint: assets.from_asset(t_trie_policy, "WRONG", 1),
    }
  t_mint(tx)
}

//(g.2) Bootstrap rejects a genesis output whose root isn't the all-zero root.
test mint_bootstrap_rejects_nonempty_root() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [
        t_trie_output(
          constants.completed_peg_outs_root_asset_name,
          #"1111111111111111111111111111111111111111111111111111111111111111",
        ),
      ],
      mint: assets.from_asset(
        t_trie_policy,
        constants.completed_peg_outs_root_asset_name,
        1,
      ),
    }
  t_mint(tx)
}

//(g.3) Bootstrap rejects a mint that doesn't spend the one-shot UTxO.
test mint_bootstrap_rejects_missing_one_shot_input() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      outputs: [
        t_trie_output(constants.completed_peg_outs_root_asset_name, t_zero_root),
      ],
      mint: assets.from_asset(
        t_trie_policy,
        constants.completed_peg_outs_root_asset_name,
        1,
      ),
    }
  t_mint(tx)
}
