use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/option
use bifrost/constants
//Aliased: the bare module name `bridge_state` is already the validator's own
//name, which the tests below call as `bridge_state.mint` / `.spend`.
use bifrost/types/bridge_state.{BridgeState} as bridge_state_types
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
  find_input, placeholder,
}

//TmSpendRedeemer Constr tags, per technical_documentation.md [CTM-14]:
//`Confirm(proof)` = Constr 0, `Gc` = Constr 1.
//LOCKSTEP: the Scalus `TmSpendRedeemer` in binocular
//(watchtower/TreasuryMovementValidator.scala) defines these tags. The two
//definitions MUST move in lockstep.
const tm_confirm_redeemer_tag: Int = 0

//Bridge state singleton (spec §Singleton validator).
//
//The singleton UTxO carries the NFT `(own policy, "BSS")` and the
//`BridgeState` datum. Only a TM Confirm spend may open it: the spend
//discriminates on the TM input's spend REDEEMER, not on a `Confirmed`
//output tag ([BSS-6]) and not on the TM NFT burn alone ([BSS-7]) — a Gc
//burn would otherwise rewrite both roots.
validator bridge_state(
  //The TM NFT policy = the binocular TreasuryMovementValidator script hash.
  //A direct parameter (not a config read): [PAR-1] only forbids
  //parameterizing READERS by the bridge state policy. The TM validator
  //finds THIS policy via the config at runtime, so there is no
  //parameterization cycle.
  tm_nft_policy_id: PolicyId,
  one_shot_input_ref: OutputReference,
) {
  //Bootstrap mint. Guarantees the NFT is unique for all time: the one-shot
  //input can be spent once, so the policy can never mint a second "BSS".
  //Assumes the datum is checked off-chain by observers, not here.
  mint(_redeemer: Data, policy_id: PolicyId, self: Transaction) {
    // spec [BSS-5] exactly one token is minted, quantity 1, asset name "BSS"
    expect [Pair(minted_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))
    expect minted_asset_name == constants.bridge_state_asset_name
    // spec [BSS-5] the token is paid to an output at the policy's own script
    //address. The datum is deliberately NOT pinned: it is operator-supplied
    //and observer-verified, serving both the first deployment and the
    //§Recovery replacement (spec §Why the bootstrap datum is not pinned).
    expect
      list.any(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(policy_id) && quantity_of(
            output.value,
            policy_id,
            constants.bridge_state_asset_name,
          ) == 1
        },
      )
    // spec [BSS-4] the bootstrap mint MUST spend the one-shot input
    option.is_some(find_input(self.inputs, one_shot_input_ref))
  }

  //Guarantees that only a TM Confirm transaction may open the singleton.
  //Assumes the TM validator pins the new `BridgeState` datum ([CTM-27]), so
  //this validator never inspects the continuing output.
  spend(
    _datum_opt: Option<Data>,
    _redeemer: Data,
    _own_ref: OutputReference,
    self: Transaction,
  ) {
    // spec [BSS-1] exactly one input sits at the TM script address ...
    expect [tm_input] =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(tm_nft_policy_id)
        },
      )
    // spec [BSS-1] ... and carries the TM NFT
    let tm_input_carries_tm_nft =
      quantity_of(
        tm_input.output.value,
        tm_nft_policy_id,
        constants.btc_asset_name,
      ) == 1
    // spec [BSS-2] that input's spend redeemer is Confirm (Constr tag 0).
    //Per [BSS-6] no `Confirmed` output tag is inspected (none exists), and
    //per [BSS-7] the TM NFT burn alone never opens the singleton: a Gc
    //spend (Constr tag 1) also burns the NFT and MUST be rejected.
    expect Some(tm_spend_redeemer) =
      pairs.get_first(self.redeemers, Spend(tm_input.output_reference))
    let Pair(tm_redeemer_tag, _fields) =
      builtin.un_constr_data(tm_spend_redeemer)
    and {
      tm_input_carries_tm_nft,
      tm_redeemer_tag == tm_confirm_redeemer_tag,
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

const t_bss_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

//The TM NFT asset name mirrors constants.btc_asset_name (empty).
const t_tm_nft_asset_name: ByteArray = ""

const t_bss_asset_name: ByteArray = "BSS"

fn t_one_shot_ref() -> OutputReference {
  OutputReference {
    transaction_id: #"0101010101010101010101010101010101010101010101010101010101010101",
    output_index: 0,
  }
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

//An arbitrary operator-supplied BridgeState datum. The mint path MUST NOT
//pin it, so any concrete values work here.
fn t_arbitrary_bridge_state() -> BridgeState {
  BridgeState {
    spi_root: #"1111111111111111111111111111111111111111111111111111111111111111",
    cpo_root: #"3333333333333333333333333333333333333333333333333333333333333333",
    treasury_utxo_id: #"444444444444444444444444444444444444444444444444444444444444444400000000",
    treasury_amount: 123_456,
  }
}

//The continuing singleton output at the policy's own script address.
fn t_singleton_output(asset_name: ByteArray) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_bss_policy),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_bss_policy, asset_name, 1),
    datum: InlineDatum(t_arbitrary_bridge_state()),
    reference_script: None,
  }
}

//A UTxO at the script address `address_policy`, carrying one NFT minted
//under `nft_policy`. The two policies are separate arguments so a test can
//place an input AT the TM address that holds a look-alike NFT under a
//foreign policy. The datum shape is irrelevant to the singleton: it
//discriminates on the spend REDEEMER, not on any datum tag ([BSS-6]).
fn t_tm_output(address_policy: ByteArray, nft_policy: ByteArray) -> Output {
  Output {
    address: Address {
      payment_credential: Script(address_policy),
      stake_credential: None,
    },
    value: assets.from_lovelace(2_000_000)
      |> assets.add(nft_policy, t_tm_nft_asset_name, 1),
    datum: InlineDatum(builtin.constr_data(0, [])),
    reference_script: None,
  }
}

fn t_tm_ref(index: Int) -> OutputReference {
  OutputReference {
    transaction_id: #"9999999999999999999999999999999999999999999999999999999999999999",
    output_index: index,
  }
}

fn t_tm_input(
  address_policy: ByteArray,
  nft_policy: ByteArray,
  index: Int,
) -> Input {
  Input {
    output_reference: t_tm_ref(index),
    output: t_tm_output(address_policy, nft_policy),
  }
}

//TmSpendRedeemer per technical_documentation.md [CTM-14]:
//Confirm(proof) = Constr 0, Gc = Constr 1.
fn t_confirm_redeemer() -> Data {
  builtin.constr_data(0, [builtin.b_data("proof")])
}

fn t_gc_redeemer() -> Data {
  builtin.constr_data(1, [])
}

fn t_mint(tx: Transaction) -> Bool {
  bridge_state.mint(t_tm_policy, t_one_shot_ref(), Void, t_bss_policy, tx)
}

fn t_spend(tx: Transaction) -> Bool {
  bridge_state.spend(
    t_tm_policy,
    t_one_shot_ref(),
    None,
    Void,
    t_dummy_own_ref(),
    tx,
  )
}

//[BSS-4] [BSS-5] Bootstrap: one-shot spent, one "BSS" token minted to the
//policy's own script address, operator-supplied BridgeState datum.
test mint_bootstrap_happy_path() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_singleton_output(t_bss_asset_name)],
      mint: assets.from_asset(t_bss_policy, t_bss_asset_name, 1),
    }
  t_mint(tx)
}

//[BSS-4] The mint MUST spend the one-shot input.
test mint_rejects_missing_one_shot() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      outputs: [t_singleton_output(t_bss_asset_name)],
      mint: assets.from_asset(t_bss_policy, t_bss_asset_name, 1),
    }
  t_mint(tx)
}

//[BSS-5] The minted asset name MUST be "BSS".
test mint_rejects_wrong_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_singleton_output("WRONG")],
      mint: assets.from_asset(t_bss_policy, "WRONG", 1),
    }
  t_mint(tx)
}

//[BSS-5] The mint MUST create exactly one token.
test mint_rejects_two_tokens() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_singleton_output(t_bss_asset_name)],
      mint: assets.from_asset(t_bss_policy, t_bss_asset_name, 2),
    }
  t_mint(tx)
}

//[BSS-5] The mint MUST create exactly one asset name under the policy.
test mint_rejects_second_asset_name() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_one_shot_input()],
      outputs: [t_singleton_output(t_bss_asset_name)],
      mint: assets.from_asset(t_bss_policy, t_bss_asset_name, 1)
        |> assets.add(t_bss_policy, "junk", 1),
    }
  t_mint(tx)
}

//[BSS-1] [BSS-2] Happy path: exactly one TM-address input carries the TM
//NFT, and the redeemers map holds Spend(that ref) -> Confirm (Constr 0).
test spend_confirm_happy() {
  let tm_input = t_tm_input(t_tm_policy, t_tm_policy, 0)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [tm_input],
      redeemers: [
        Pair(Spend(tm_input.output_reference), t_confirm_redeemer()),
      ],
    }
  t_spend(tx)
}

//[BSS-1] No input at the TM script address.
test spend_rejects_no_tm_input() fail {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      redeemers: [Pair(Spend(t_tm_ref(0)), t_confirm_redeemer())],
    }
  t_spend(tx)
}

//[BSS-1] Two TM-address inputs: "exactly one" is violated.
test spend_rejects_two_tm_inputs() fail {
  let tm_input_a = t_tm_input(t_tm_policy, t_tm_policy, 0)
  let tm_input_b = t_tm_input(t_tm_policy, t_tm_policy, 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [tm_input_a, tm_input_b],
      redeemers: [
        Pair(Spend(tm_input_a.output_reference), t_confirm_redeemer()),
        Pair(Spend(tm_input_b.output_reference), t_confirm_redeemer()),
      ],
    }
  t_spend(tx)
}

//[BSS-2] [BSS-7] The TM input is spent with Gc (Constr 1) and the TM NFT is
//burned in the same tx. The NFT burn alone MUST NOT open the singleton.
test spend_rejects_gc_redeemer() fail {
  let tm_input = t_tm_input(t_tm_policy, t_tm_policy, 0)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [tm_input],
      redeemers: [Pair(Spend(tm_input.output_reference), t_gc_redeemer())],
      mint: assets.from_asset(t_tm_policy, t_tm_nft_asset_name, -1),
    }
  t_spend(tx)
}

//[BSS-1] The input sits AT the real TM script address, but its NFT is a
//look-alike minted under a foreign policy. This exercises the
//`tm_input_carries_tm_nft` conjunct: the address filter matches, so the
//spend reaches the NFT check and MUST reject there.
test spend_rejects_wrong_tm_policy() fail {
  let foreign_policy =
    #"ff777777777777777777777777777777777777777777777777777777"
  let tm_input = t_tm_input(t_tm_policy, foreign_policy, 0)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [tm_input],
      redeemers: [
        Pair(Spend(tm_input.output_reference), t_confirm_redeemer()),
      ],
    }
  t_spend(tx)
}
