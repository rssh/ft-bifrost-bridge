use aiken/builtin
use aiken/collection/list
use aiken/interval
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/constants
use bifrost/types/config.{ConfigDatum, ScheduleParams}
use bifrost/types/general.{CardanoSignature}
use bifrost/types/peg_out.{
  Cancel, CompletePegOut, PegOutActionType, PegOutDatum, PegOutWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Script}
use cardano/assets.{Value, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
  placeholder,
}

//Grace period before an unfulfilled PegOut request may be cancelled:
//30 days in ms. A validator constant (like the TM GC grace) — tunable only by
//a peg_out script swap via config Update (field 5).
pub const peg_out_cancel_timeout_ms: Int = 2_592_000_000

validator peg_out_validator(
  config_nft_policy_id: ByteArray,
  config_nft_asset_name: ByteArray,
) {
  withdraw(
    redeemer: PegOutWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config_fields = utils.get_config_as_data_list(
      utils.safe_list_at(self.reference_inputs, redeemer.config_ref_input_index),
      config_nft_policy_id,
      config_nft_asset_name,
    )
    let bridged_token_policy_id = config.get_bridged_token_policy_id(
      config_fields,
    )
    let bridged_token_asset_name = config.get_bridged_token_asset_name(
      config_fields,
    )
    let completed_peg_outs_policy_id = config.get_completed_peg_outs_merkle_tree_policy_id(
      config_fields,
    )

    //The completed-peg-outs trie is a REFERENCE input (never spent here):
    //authenticated by its NFT, it pins the current root — a stale root is
    //impossible (a spent trie outpoint cannot be referenced).
    let trie_ref_input = utils.safe_list_at(
      self.reference_inputs,
      redeemer.completed_peg_outs_ref_input_index,
    )
    expect
      quantity_of(
        trie_ref_input.output.value,
        completed_peg_outs_policy_id,
        constants.completed_peg_outs_root_asset_name,
      ) == 1
    let completed_peg_outs = utils.get_mpf_from_output(trie_ref_input.output)

    expect [peg_out_input] = list.filter(
      self.inputs,
      fn(input) { input.output.address.payment_credential == credential },
    )
    expect InlineDatum(input_datum) = peg_out_input.output.datum
    expect datum: PegOutDatum = input_datum

    //POR id: hash of this request's own outpoint — globally unique, needs no
    //datum field, and is exactly the key the quorum inserted into the
    //completed-peg-outs trie whose root the TM Confirm attested.
    let por_id = utils.hash_output_ref(peg_out_input.output_reference)

    let bridged_tokens_locked = quantity_of(
      peg_out_input.output.value,
      bridged_token_policy_id,
      bridged_token_asset_name,
    )

    when redeemer.action_type is {
      CompletePegOut { membership_proof } -> {
        //Completion is permissionless cleanup: it can only burn the exact
        //locked fBTC against a value-bound attested payment (the trie root
        //is quorum-attested at TM Confirm, spec rev 5.1), so authorization
        //adds nothing. Nothing here constrains the POR's non-fBTC content,
        //so the completer takes it all: the MIN_ADA, plus any overfunded
        //lovelace or stray tokens a careless creator locked in. Surplus
        //cannot be routed back on-chain (owner_auth is an
        //AuthorizationMethod, not an address). Request-creation tooling
        //MUST NOT overfund PORs — this is a client-side check.
        //The confirmed TM paid dest exactly (locked − pinned fee) satoshi:
        //the trie maps this POR id to dest_spk ++ amount_le8 (8-byte LE).
        let net_amount = bridged_tokens_locked - datum.per_pegout_fee
        let expected_value = bytearray.concat(
          datum.source_chain_destination_address,
          builtin.integer_to_bytearray(False, 8, net_amount),
        )
        let fulfilled_proven = mpf.has(
          completed_peg_outs,
          por_id,
          expected_value,
          membership_proof,
        )
        //All locked fBTC burnt — completion consumes the request entirely.
        //No trie insert: once-only completion is structural (unique POR id,
        //single-spend POR UTxO, and one trie entry per paid request).
        let all_bridged_tokens_burnt = quantity_of(
          self.mint,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == -bridged_tokens_locked
        and {
          fulfilled_proven,
          all_bridged_tokens_burnt,
        }
      }
      Cancel { exclusion_proof } -> {
        //Refund path: only the owner may cancel and reclaim their own
        //locked fBTC.
        let user_authorized = authorize_action(
          create_auth(
            datum.owner_auth,
            self.inputs,
            self.reference_inputs,
            self.withdrawals,
            self.extra_signatories,
            self.mint,
          ),
        )
        //After the timeout, an id absent from the trie can never
        //be paid (the SPO freshness margin stops fulfillment long before the
        //deadline), so the fBTC unlocks back to the owner.
        let timeout_elapsed = interval.is_entirely_after(
          self.validity_range,
          datum.created + peg_out_cancel_timeout_ms,
        )
        let not_fulfilled = mpf.miss(
          completed_peg_outs,
          por_id,
          exclusion_proof,
        )
        //A cancel must never mint or burn the bridged token: this keeps
        //bridged_token's presence-only delegation sound.
        let no_bridged_token_mint = quantity_of(
          self.mint,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == 0
        and {
          user_authorized,
          timeout_elapsed,
          not_fulfilled,
          no_bridged_token_mint,
        }
      }
    }
  }

  spend(
    _datumOpt: Option<Data>,
    _redeemer: Data,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = list.find(
      self.inputs,
      fn(input) { input.output_reference == own_ref },
    )
    expect Script(own_script_hash) = own_input.output.address.payment_credential
    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(script_hash), _amnt) -> script_hash == own_script_hash
          _ -> False
        }
      },
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests
//----------------------------------------------------------------------------

const t_config_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_asset: ByteArray = "BifrostConfig"

const t_peg_out_script_hash: ByteArray =
  #"aa555555555555555555555555555555555555555555555555555555"

const t_bridged_token_policy: ByteArray =
  #"aa111111111111111111111111111111111111111111111111111111"

const t_bridged_token_asset: ByteArray = "fSAT"

const t_completed_peg_outs_policy: ByteArray =
  #"bb222222222222222222222222222222222222222222222222222222"

const t_owner_hash: ByteArray =
  #"dd333333333333333333333333333333333333333333333333333333"

const t_dest_spk: ByteArray = #"0014abababababababababababababababababab"

//An arbitrary POSIX-ms creation time. Cancel tests offset validity ranges
//relative to it + peg_out_cancel_timeout_ms.
const t_created: Int = 1_700_000_000_000

//A locally-scoped mirror of `CompletedPegOutsMerkleTreeDatum` (Task 1): its
//only requirement, per `utils.get_mpf_from_output`, is that the root is the
//first field of the inline datum.
type TrieDatum {
  root: ByteArray,
}

fn t_config_datum() -> ConfigDatum {
  ConfigDatum {
    bridged_token_policy_id: t_bridged_token_policy,
    bridged_token_asset_name: t_bridged_token_asset,
    completed_peg_ins_merkle_tree_policy_id: #"aa22",
    completed_peg_outs_merkle_tree_policy_id: t_completed_peg_outs_policy,
    peg_in_withdraw_script_hash: #"aa44",
    peg_out_withdraw_script_hash: t_peg_out_script_hash,
    peg_in_close_verifier_script_hash: #"aa66",
    legit_treasury_movement_and_peg_out_produced_verifier_script_hash: #"aa77",
    legit_treasury_movement_and_peg_out_not_produced_verifier_script_hash: #"aa88",
    min_stake: 0,
    update_auth: Some(CardanoSignature { hash: #"aadd" }),
    initial_btc_treasury_utxo: #"aaee",
    fee_rate_sat_per_vb: 1,
    per_pegout_fee: 1000,
    min_peg_out_fbtc: 10000,
    leader_reward: 2_000_000,
    schedule: ScheduleParams {
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
    spo_bans_policy_id: #"aabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    base_ban_duration_ms: 600_000,
    max_faults_before_permanent: 3,
    max_validity_window_ms: 3_600_000,
    spos_registry_policy_id: #"aacccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    treasury_info_policy_id: #"aadddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    treasury_info_asset_name: "TMTx",
  }
}

fn t_config_ref_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_config_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_config_policy, t_config_asset, 1),
      datum: InlineDatum(t_config_datum()),
      reference_script: None,
    },
  }
}

//The completed-peg-outs trie reference input, carrying the CPO NFT (unless
//`with_nft` is False, used by the missing-NFT test) and the given root.
fn t_trie_ref_input(root: ByteArray, with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value = if with_nft {
    base
      |> assets.add(
          t_completed_peg_outs_policy,
          constants.completed_peg_outs_root_asset_name,
          1,
        )
  } else {
    base
  }
  Input {
    output_reference: OutputReference {
      transaction_id: #"2222222222222222222222222222222222222222222222222222222222222222",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_completed_peg_outs_policy),
        stake_credential: None,
      },
      value,
      datum: InlineDatum(TrieDatum { root }),
      reference_script: None,
    },
  }
}

fn t_peg_out_own_ref() -> OutputReference {
  OutputReference {
    transaction_id: #"3333333333333333333333333333333333333333333333333333333333333333",
    output_index: 0,
  }
}

//The POR id the validator derives from `t_peg_out_own_ref()`.
fn t_por_id() -> ByteArray {
  utils.hash_output_ref(t_peg_out_own_ref())
}

fn t_peg_out_datum(fee: Int) -> PegOutDatum {
  PegOutDatum {
    owner_auth: CardanoSignature { hash: t_owner_hash },
    source_chain_destination_address: t_dest_spk,
    per_pegout_fee: fee,
    created: t_created,
  }
}

fn t_peg_out_input(locked_amount: Int, fee: Int) -> Input {
  Input {
    output_reference: t_peg_out_own_ref(),
    output: Output {
      address: Address {
        payment_credential: Script(t_peg_out_script_hash),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_bridged_token_policy,
            t_bridged_token_asset,
            locked_amount,
          ),
      datum: InlineDatum(t_peg_out_datum(fee)),
      reference_script: None,
    },
  }
}

//The trie value the validator expects to find at `por_id` on Complete:
//dest_spk ++ net_amount as 8-byte little-endian.
fn t_expected_value(net_amount: Int) -> ByteArray {
  bytearray.concat(
    t_dest_spk,
    builtin.integer_to_bytearray(False, 8, net_amount),
  )
}

fn t_withdraw(
  peg_out_input: Input,
  trie_ref_input: Input,
  action: PegOutActionType,
  mint: Value,
  extra_signatories: List<ByteArray>,
  validity_range: ValidityRange,
) -> Bool {
  let tx = Transaction {
    ..placeholder,
    inputs: [peg_out_input],
    reference_inputs: [t_config_ref_input(), trie_ref_input],
    mint,
    extra_signatories,
    validity_range,
  }
  peg_out_validator.withdraw(
    t_config_policy,
    t_config_asset,
    PegOutWithdrawRedeemer {
      config_ref_input_index: 0,
      completed_peg_outs_ref_input_index: 1,
      action_type: action,
    },
    Script(t_peg_out_script_hash),
    tx,
  )
}

// -----------------------------------------------------------------------------
// Complete
// -----------------------------------------------------------------------------

const t_locked: Int = 100_000

const t_fee: Int = 1_000

//net_amount = t_locked - t_fee = 99_000; the trie a well-behaved TM Confirm
//would have produced for this request.
fn t_happy_trie() -> Input {
  let trie = mpf.insert(
    mpf.empty,
    t_por_id(),
    t_expected_value(t_locked - t_fee),
    [],
  )
  t_trie_ref_input(mpf.root(trie), True)
}

test complete_happy_path() {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_happy_trie(),
    CompletePegOut { membership_proof: [] },
    assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, -t_locked),
    [t_owner_hash],
    interval.everything,
  )
}

//Fee arithmetic: the request pins fee = 1_001 (one more than what the trie
//was built against), so net_amount is off by one and the committed trie
//value no longer matches.
test complete_rejects_wrong_value() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee + 1),
    t_happy_trie(),
    CompletePegOut { membership_proof: [] },
    assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, -t_locked),
    [t_owner_hash],
    interval.everything,
  )
}

//The trie only knows a different POR id (a foreign request); this request's
//own outpoint hashes to a different id, so no membership proof can match.
test complete_rejects_wrong_id() fail {
  let foreign_id = utils.hash_output_ref(
    OutputReference {
      transaction_id: #"9999999999999999999999999999999999999999999999999999999999999999",
      output_index: 0,
    },
  )
  let trie = mpf.insert(
    mpf.empty,
    foreign_id,
    t_expected_value(t_locked - t_fee),
    [],
  )
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_trie_ref_input(mpf.root(trie), True),
    CompletePegOut { membership_proof: [] },
    assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, -t_locked),
    [t_owner_hash],
    interval.everything,
  )
}

test complete_rejects_partial_burn() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_happy_trie(),
    CompletePegOut { membership_proof: [] },
    assets.from_asset(
      t_bridged_token_policy,
      t_bridged_token_asset,
      -(t_locked - 1),
    ),
    [t_owner_hash],
    interval.everything,
  )
}

//Completion is permissionless cleanup (spec rev 5.1): a third party who
//never signed as the owner can still complete a fulfilled request.
test complete_by_third_party_succeeds() {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_happy_trie(),
    CompletePegOut { membership_proof: [] },
    assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, -t_locked),
    [#"ee999999999999999999999999999999999999999999999999999999"],
    interval.everything,
  )
}

// -----------------------------------------------------------------------------
// Cancel
// -----------------------------------------------------------------------------

//The empty trie: por_id is provably absent with the empty proof
//(`excluding(key, []) == empty.root` for any key).
fn t_empty_trie() -> Input {
  t_trie_ref_input(mpf.root(mpf.empty), True)
}

test cancel_happy_path_after_timeout() {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_empty_trie(),
    Cancel { exclusion_proof: [] },
    assets.zero,
    [t_owner_hash],
    interval.after(t_created + peg_out_cancel_timeout_ms + 1),
  )
}

//Boundary: validity lower bound == created + timeout exactly. `is_entirely_after`
//requires the point to be strictly less than an inclusive lower bound, so an
//equal boundary must still FAIL.
test cancel_rejects_inside_timeout_boundary() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_empty_trie(),
    Cancel { exclusion_proof: [] },
    assets.zero,
    [t_owner_hash],
    interval.after(t_created + peg_out_cancel_timeout_ms),
  )
}

//The trie already carries this POR id (it was fulfilled): the empty proof
//no longer reconstructs the trie root, so `miss` correctly returns False.
test cancel_rejects_membership_id() fail {
  let trie = mpf.insert(
    mpf.empty,
    t_por_id(),
    t_expected_value(t_locked - t_fee),
    [],
  )
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_trie_ref_input(mpf.root(trie), True),
    Cancel { exclusion_proof: [] },
    assets.zero,
    [t_owner_hash],
    interval.after(t_created + peg_out_cancel_timeout_ms + 1),
  )
}

test cancel_rejects_minting_fbtc() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_empty_trie(),
    Cancel { exclusion_proof: [] },
    assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, 1),
    [t_owner_hash],
    interval.after(t_created + peg_out_cancel_timeout_ms + 1),
  )
}

//A third party (not the owner) cannot cancel someone else's expired request.
test cancel_rejects_not_authorized() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_empty_trie(),
    Cancel { exclusion_proof: [] },
    assets.zero,
    [#"ee999999999999999999999999999999999999999999999999999999"],
    interval.after(t_created + peg_out_cancel_timeout_ms + 1),
  )
}

// -----------------------------------------------------------------------------
// Shared
// -----------------------------------------------------------------------------

//The reference input at the CPO trie's address is missing the CPO NFT: it
//cannot authenticate a root, so the withdrawal must trap rather than trust it.
test withdraw_rejects_missing_trie_nft() fail {
  t_withdraw(
    t_peg_out_input(t_locked, t_fee),
    t_trie_ref_input(mpf.root(mpf.empty), False),
    Cancel { exclusion_proof: [] },
    assets.zero,
    [t_owner_hash],
    interval.after(t_created + peg_out_cancel_timeout_ms + 1),
  )
}
