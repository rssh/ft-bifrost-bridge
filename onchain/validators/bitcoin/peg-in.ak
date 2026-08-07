use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use bifrost/bip322
use bifrost/bitcoin
use bifrost/constants
use bifrost/types/bridge_state.{BridgeState}
use bifrost/types/config
use bifrost/types/general.{CardanoSignature, ChainState}
use bifrost/types/peg_in.{
  Cancel, CompletePegIn, PegInDatum, PegInMintRedeemer, PegInRequest,
  PegInWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
  placeholder,
}

// Domain-separation tag "BFR-mint-v1" for the depositor completion-signing message (BIP340
// practice; technical_documentation.md §"Complete peg-in"). Must equal binocular
// BifrostMessages.mintTag.
const mint_tag: ByteArray = #"4246522d6d696e742d7631"

/// PegInRequest lifecycle: mint a request bound to a confirmed Bitcoin deposit, then complete it
/// into fBTC once the bridge state singleton attests the deposit was swept.
///
/// Guarantees:
/// - a minted PegInRequest describes a real, block-confirmed deposit (`bitcoin.deposit_binding_ok`);
/// - fBTC is minted only for a deposit the singleton's `spi_root` records as swept ([CPI-9]);
/// - only the depositor's Bitcoin key can direct that mint, and only to one address ([CPI-3]);
/// - a deposit mints at most once (CPI-trie exclusion before, insert after).
///
/// Assumes:
/// - the Config UTxO named by `config_nft_policy_id` / `config_nft_asset_name` is honest: it is the
///   root of trust for the bridged-token, CPI-trie and bridge-state policy ids. There is
///   deliberately no `tm_nft_policy_id` parameter — the singleton policy is read from Config at
///   runtime ([PAR-1]), so rotating it needs no re-parameterisation and no address change;
/// - the singleton's `spi_root` is quorum-attested at TM Confirm. This validator re-verifies the
///   membership proof but never the sweep itself.
validator peg_in_validator(
  oracle_policy_id: PolicyId,
  config_nft_policy_id: PolicyId,
  config_nft_asset_name: AssetName,
) {
  mint(redeemer: PegInMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent = option.is_some(
      find_input(self.inputs, redeemer.input_ref),
    )

    let minted_positive = list.filter(
      dict.to_pairs(tokens(self.mint, policy_id)),
      fn(Pair(_asset_name, quantity)) { quantity > 0 },
    )
    when minted_positive is {
      // Burn-only: no positive mint under this policy. Permitted – the PIR being burned can only
      // be spent via this script's spend handler, which forces a peg_in withdrawal, and the
      // withdraw handler gates the burn: CompletePegIn requires it ([CPI-8]) and Cancel requires
      // it too (transitionally hard False; the clr-close-pir task wires the SPI-trie close). A
      // burn tx need not reference an oracle / deposit, so it must not be forced through the
      // mint-time checks below.
      [] -> True
      [Pair(minted_asset_name, 1)] -> {
        //Oracle reference input
        expect Some(oracle_ref_input) = list.find(
          self.reference_inputs,
          fn(input) {
            assets.quantity_of(input.output.value, oracle_policy_id, #"") == 1
          },
        )
        expect InlineDatum(oracle_raw) = oracle_ref_input.output.datum
        expect ChainState { confirmed_blocks_root, .. } = oracle_raw

        expect [peg_in_output] = list.filter(
          self.outputs,
          fn(output) { output.address.payment_credential == Script(policy_id) },
        )

        let peg_in_request = redeemer.new_peg_in_request
        //The PegIn amount must be always > 0
        let peg_in_amount_positive = builtin.un_i_data(
          peg_in_request.expected_datum.peg_in_amount,
        ) > 0

        //AssetName must be input_ref_hash
        let correct_asset_name = minted_asset_name == input_ref_hash

        //Output must have 1 token with quantity 1
        let output_has_unique_token = assets.quantity_of(
          peg_in_output.value,
          policy_id,
          minted_asset_name,
        ) == 1
        //Output must contain proper InlineDatum
        let output_has_correct_datum = peg_in_output.datum == InlineDatum(
          peg_in_request.expected_datum,
        )

        let block_hash = utils.bitcoin_hash(peg_in_request.block_header)
        //Block header must belong to the official source chain
        let block_header_included_in_source_chain = mpf.has(
          mpf.from_root(confirmed_blocks_root),
          block_hash,
          block_hash,
          peg_in_request.block_header_in_source_chain_inclusion_proof,
        )
        let peg_in_request_tx_hash = utils.bitcoin_hash(
          peg_in_request.expected_datum.source_chain_peg_in_raw_tx,
        )
        //Tx must belong to the block
        let peg_in_request_tx_included_in_block_header = bitcoin.verify_tx_merkle_proof(
          peg_in_request_tx_hash,
          peg_in_request.expected_datum.source_chain_peg_in_raw_tx_index,
          peg_in_request.tx_in_block_header_inclusion_proof,
          bitcoin.block_merkle_root(peg_in_request.block_header),
        )

        // Bind the PegInDatum to the (now block-confirmed) deposit tx. Minting is permissionless, so
        // without this an attacker could mint a PIR claiming an arbitrary outpoint / amount / pubkey
        // and then (since B1 embeds the depositor Schnorr auth at completion) sign with THEIR OWN
        // key. The completion's "only the depositor can submit" guarantee is only real if the datum's
        // peg_in_utxo_id / peg_in_amount / user_source_chain_pub_key describe Alice's actual deposit.
        // peg_in_request_tx_hash is the deposit txid (sha256d of the witness-stripped tx — the merkle
        // proof above already forces the stripped serialization). The binding is extracted into
        // bitcoin.deposit_binding_ok (unit-tested there). Closes review findings #1–#4.
        let deposit_bound =
          bitcoin.deposit_binding_ok(
            peg_in_request.expected_datum.source_chain_peg_in_raw_tx,
            peg_in_request_tx_hash,
            peg_in_request.expected_datum.peg_in_utxo_id,
            peg_in_request.expected_datum.peg_in_amount,
            peg_in_request.expected_datum.user_source_chain_pub_key,
          )
        and {
          is_input_ref_spent,
          peg_in_amount_positive,
          correct_asset_name,
          output_has_unique_token,
          output_has_correct_datum,
          block_header_included_in_source_chain,
          peg_in_request_tx_included_in_block_header,
          deposit_bound,
        }
      }
      _ -> False
    }
  }

  withdraw(
    redeemer: PegInWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config_fields = utils.get_config_as_data_list(
      utils.safe_list_at(self.reference_inputs, redeemer.config_ref_input_index),
      config_nft_policy_id,
      config_nft_asset_name,
    )
    let bridged_token_policy_id =
      config.get_bridged_token_policy(config_fields)
    //spec [CFG-1]: the asset name is a protocol constant, not a Config field
    let bridged_token_asset_name = constants.bridged_token_asset_name
    let completed_peg_ins_merkle_tree_policy_id =
      config.get_completed_peg_ins_policy(config_fields)
    let completed_peg_ins_merkle_tree_asset_name =
      constants.completed_peg_ins_root_asset_name
    expect [peg_in_input] = list.filter(
      self.inputs,
      fn(input) { input.output.address.payment_credential == credential },
    )
    when redeemer.action_type is {
      Cancel { burnt_peg_in_nft_asset_name } -> {
        expect Script(peg_in_policy_id) = credential
        //TRANSITIONAL: hard False, replaced by the clr-close-pir task. The
        //rev-5.1 Cancel path delegated the close checks to the (never
        //deployed) peg-in close verifier; its ConfigDatum field is removed in
        //the rev-5.4 seven-field layout (spec §Config datum). The deployed
        //field held a dummy hash with no reward account, so Cancel was
        //already unsatisfiable; False preserves that behavior exactly until
        //the SPI-trie close ([CLR-5]/[CLR-6]/[CLR-8]) replaces this branch.
        let close_authorized = False
        //Input must contain a PegIn nft
        let peg_in_nft_in_input = quantity_of(
          peg_in_input.output.value,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == 1
        //The input PegIn nft must be burnt
        let peg_in_nft_burnt = quantity_of(
          self.mint,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == -1
        //A close/cancel must never mint or burn the bridged token: this is what
        //keeps bridged_token's presence-only delegation sound (a Cancel can not
        //smuggle an unconstrained fSAT mint).
        let no_bridged_token_mint =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
        and {
          close_authorized,
          peg_in_nft_in_input,
          peg_in_nft_burnt,
          no_bridged_token_mint,
        }
      }
      CompletePegIn {
        recipient,
        fbtc_output_index,
        depositor_signature,
        completed_peg_in_utxos_input_index,
        completed_peg_in_utxos_output_index,
        added_peg_in_to_completed_peg_ins_inclusion_proof,
        peg_in_in_completed_peg_ins_exclusion_proof,
        bridge_state_ref_input_index,
        sweeping_tm_input_0,
        peg_in_swept_membership_proof,
      } -> {
        expect InlineDatum(input_datum) = peg_in_input.output.datum
        expect datum: PegInDatum = input_datum

        // 0. Authenticate the spent request. The input must carry exactly one
        //    PegInRequest NFT under this script's own policy: the NFT is the
        //    only thing that ties the inline datum (peg_in_amount,
        //    peg_in_utxo_id, user_source_chain_pub_key) to a deposit the mint
        //    handler actually verified. Without it, anyone could park a
        //    hand-made PegInDatum at this address naming a genuinely swept
        //    outpoint and mint arbitrary fBTC under their own key.
        //spec [CPI-8]
        expect Script(peg_in_policy_id) = credential
        expect [Pair(pir_nft_asset_name, 1)] =
          dict.to_pairs(tokens(peg_in_input.output.value, peg_in_policy_id))
        //spec [CPI-8]: the NFT must be burned — it must not outlive the
        //request, or it could later authenticate a forged datum.
        let peg_in_nft_burnt =
          quantity_of(self.mint, peg_in_policy_id, pir_nft_asset_name) == -1

        // 1. Reference the bridge state singleton. spec [PAR-1]: its policy comes
        //    from the Config reference input at runtime, not a validator parameter.
        //    spec [CPI-10]: the NFT (bridge_state_policy, "BSS") — not the address —
        //    is the trust anchor: it can only live under the gated singleton policy.
        //    Located by redeemer index rather than by scanning reference_inputs for
        //    the NFT: the scan costs O(reference_inputs) and, worse, would silently
        //    pick a different UTxO if one ever matched, whereas a wrong index traps.
        //spec [PAR-1]
        let bridge_state_policy = config.get_bridge_state_policy(config_fields)
        let bridge_state_ref_input = utils.safe_list_at(
          self.reference_inputs,
          bridge_state_ref_input_index,
        )
        //spec [CPI-10]
        expect
          quantity_of(
            bridge_state_ref_input.output.value,
            bridge_state_policy,
            constants.bridge_state_asset_name,
          ) == 1
        //spec [LIB-1]: decode the singleton datum as BridgeState and read
        //spi_root BY NAME. spec [LIB-2]: never utils.get_mpf_from_output here —
        //a blind field-0 read returns spi_root only by accident of the current
        //field order, and would silently return the wrong root if it changed.
        expect InlineDatum(state_raw) = bridge_state_ref_input.output.datum
        expect state: BridgeState = state_raw

        // 2. This deposit must have been swept: the singleton's spi_root maps
        //    peg_in_utxo_id to the sweeping TM's input-0 outpoint (36 bytes),
        //    which the TM Confirm attested.
        //spec [CPI-9]
        let peg_in_swept = mpf.has(
          mpf.from_root(state.spi_root),
          datum.peg_in_utxo_id,
          sweeping_tm_input_0,
          peg_in_swept_membership_proof,
        )

        // 3. Depositor authorization via BIP-322 (taproot key-path), so a normal Bitcoin wallet's
        //    signMessage(msg,"bip322-simple") suffices — no raw-key access. The depositor signs the
        //    ASCII text  "BFR-mint-v1:" ++ hex(binding_digest)  where binding_digest is
        //    sha2_256(mint_tag ‖ peg_in_utxo_id ‖ recipient). No btc_txid: sweep membership is
        //    proven against the singleton in step 2, so the message needs no TM binding. Binding
        //    recipient + the deposit outpoint keeps a leaked signature non-replayable.
        //    user_source_chain_pub_key is the depositor wallet's taproot OUTPUT key (the address's
        //    witness program); deposit_binding_ok ties it to the deposit's OP_RETURN beacon.
        //spec [CPI-3]
        let binding_digest =
          mint_tag
            |> bytearray.concat(datum.peg_in_utxo_id)
            |> bytearray.concat(builtin.serialise_data(recipient))
            |> crypto.sha2_256
        let signed_message =
          mint_tag
            |> bytearray.concat(#"3a")
            |> bytearray.concat(bip322.hex_lower(binding_digest))
        let depositor_authorized =
          bip322.verify_keypath(
            datum.user_source_chain_pub_key,
            signed_message,
            depositor_signature,
          )

        // 4. Recipient-binding: the minted fBTC goes to `recipient` in exactly peg_in_amount.
        let fbtc_output = utils.safe_list_at(self.outputs, fbtc_output_index)
        let fbtc_to_recipient = fbtc_output.address == recipient
        let fbtc_amount_to_recipient = quantity_of(
          fbtc_output.value,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == datum.peg_in_amount

        // 5. Completed-peg-ins MPF bookkeeping (unchanged): the peg-in is inserted, was absent
        //    before, and the MPF UTxO keeps its value + address.
        let completed_peg_in_utxos_input = utils.safe_list_at(
          self.inputs,
          completed_peg_in_utxos_input_index,
        )
        //Complete PegIns merkle tree input must have the unique NFT
        expect
          quantity_of(
            completed_peg_in_utxos_input.output.value,
            completed_peg_ins_merkle_tree_policy_id,
            completed_peg_ins_merkle_tree_asset_name,
          ) == 1
        let input_completed_peg_in_merkle_tree = utils.get_mpf_from_output(
          completed_peg_in_utxos_input.output,
        )
        let completed_peg_in_utxos_output = utils.safe_list_at(
          self.outputs,
          completed_peg_in_utxos_output_index,
        )
        //Complete PegIns merkle tree output must have the unique NFT
        expect
          quantity_of(
            completed_peg_in_utxos_output.value,
            completed_peg_ins_merkle_tree_policy_id,
            completed_peg_ins_merkle_tree_asset_name,
          ) == 1
        let output_completed_peg_in_merkle_tree = utils.get_mpf_from_output(
          completed_peg_in_utxos_output,
        )
        //Completed PegIn have been added to the completed PegIns merkle tree.
        //spec §The two deposit tries: the inserted VALUE is the sweeping TM's
        //input-0 outpoint — the same value the SPI trie holds — not the key.
        let added_completed_peg_ins_to_merkle_tree = mpf.insert(
          input_completed_peg_in_merkle_tree,
          datum.peg_in_utxo_id,
          sweeping_tm_input_0,
          added_peg_in_to_completed_peg_ins_inclusion_proof,
        ) == output_completed_peg_in_merkle_tree
        //The completed_peg_in_utxos must not change in value
        let same_completed_peg_in_utxos_value = without_lovelace(
          completed_peg_in_utxos_input.output.value,
        ) == without_lovelace(completed_peg_in_utxos_output.value)
        //The completed_peg_in_utxos must not change address
        let same_completed_peg_in_utxos_address = completed_peg_in_utxos_input.output.address == completed_peg_in_utxos_output.address
        //The PegIn must not yet be in the completed_peg_in merkle tree
        let completed_peg_in_exclusion_proven = mpf.miss(
          input_completed_peg_in_merkle_tree,
          datum.peg_in_utxo_id,
          peg_in_in_completed_peg_ins_exclusion_proof,
        )

        //spec [CPI-6]: total fBTC minted equals peg_in_amount exactly
        let bridged_tokens_minted = quantity_of(
          self.mint,
          bridged_token_policy_id,
          bridged_token_asset_name,
        ) == datum.peg_in_amount
        and {
          peg_in_nft_burnt,
          peg_in_swept,
          depositor_authorized,
          fbtc_to_recipient,
          fbtc_amount_to_recipient,
          completed_peg_in_exclusion_proven,
          added_completed_peg_ins_to_merkle_tree,
          same_completed_peg_in_utxos_value,
          same_completed_peg_in_utxos_address,
          bridged_tokens_minted,
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
// Tests — CompletePegIn against the bridge state singleton (spec rev 5.4:
// [CPI-9], [CPI-10], revised [CPI-3], [CPI-6], [PAR-1])
//----------------------------------------------------------------------------

const t_config_policy: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_config_asset: ByteArray = "BifrostConfig"

const t_oracle_policy: ByteArray =
  #"ee111111111111111111111111111111111111111111111111111111"

const t_peg_in_script_hash: ByteArray =
  #"aa444444444444444444444444444444444444444444444444444444"

const t_bridged_token_policy: ByteArray =
  #"aa111111111111111111111111111111111111111111111111111111"

//spec [CFG-1]: the same protocol constant the validator reads
const t_bridged_token_asset: ByteArray = constants.bridged_token_asset_name

const t_cpi_policy: ByteArray =
  #"aa222222222222222222222222222222222222222222222222222222"

const t_bridge_state_policy: ByteArray =
  #"bb222222222222222222222222222222222222222222222222222222"

//x-only pubkey of BIP340 secret key 1 (the generator point) — the same
//vector treasury.ak's Update-Y tests sign under.
const t_user_pub_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

//The deposit outpoint: txid aa*32 ++ vout 1 LE(4). 36 bytes.
const t_peg_in_utxo_id: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01000000"

//The sweeping TM's input-0 outpoint (the head it spent): bb*32 ++ 00000000.
//36 bytes. The SPI trie value for t_peg_in_utxo_id, and the value the CPI
//trie insert must record (spec §The two deposit tries).
const t_tm_input_0: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb00000000"

const t_recipient_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_peg_in_amount: Int = 100_000

//BIP-322 keypath signature by secret key 1 over the REVISED [CPI-3] message:
//"BFR-mint-v1" ++ ":" ++ hex_lower(sha2_256(mint_tag ‖ t_peg_in_utxo_id ‖
//serialise_data(t_recipient()))). No btc_txid. Generated with the BIP340
//reference algorithm against this module's bip322.keypath_message_hash.
const t_sig_new: ByteArray =
  #"198192636c61d08f5cf95f7a5e8e49895f241b35251fba292e428a445aa66543ebafa8faa00af80fa8914ed53353a1adc15d279787d388720335c3f3c724138b"

//Same signer, but over the rev-5.1 digest INCLUDING a btc_txid (33*32):
//sha2_256(mint_tag ‖ btc_txid ‖ peg_in_utxo_id ‖ recipient). A genuine
//signature over the OLD message must no longer authorize a completion.
const t_sig_old: ByteArray =
  #"01323449150b14c18612fa93a491d198602ddcad94d9b49c81d6463d7655a6f327afedddc079d0697f5369d3a3a1fb4c70e005a48c19849c0ef0feed6790b25b"

//The trie root that maps this deposit to its sweeping TM's input-0 outpoint.
//Both deposit tries hold the same pair (spec §The two deposit tries: 'Value =
//the same'), so this is the swept singleton's spi_root AND the CPI trie root
//a well-formed completion must produce.
fn t_swept_root() -> ByteArray {
  mpf.insert(mpf.empty, t_peg_in_utxo_id, t_tm_input_0, []) |> mpf.root
}

fn t_recipient() -> Address {
  Address {
    payment_credential: VerificationKey(t_recipient_hash),
    stake_credential: None,
  }
}

//The rev-5.4 seven-field Config datum (spec §Config datum), raw on purpose:
//readers use positional getters, so the fixture mirrors the wire encoding.
fn t_config_datum_data() -> Data {
  let update_auth_data: Data = Some(CardanoSignature { hash: #"aadd" })
  let params_data: Data =
    builtin.constr_data(
      0,
      [
        builtin.i_data(1),
        builtin.i_data(1000),
        builtin.i_data(10000),
        builtin.i_data(0),
      ],
    )
  builtin.constr_data(
    0,
    [
      update_auth_data,
      builtin.b_data(t_bridged_token_policy),
      builtin.b_data(t_cpi_policy),
      builtin.b_data(t_bridge_state_policy),
      builtin.b_data(t_peg_in_script_hash),
      builtin.b_data(#"aa555555555555555555555555555555555555555555555555555555"),
      params_data,
    ],
  )
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
      datum: InlineDatum(t_config_datum_data()),
      reference_script: None,
    },
  }
}

//The bridge state singleton as a REFERENCE input, carrying the 4-field
//BridgeState datum. spec [CPI-10]: authenticated by the NFT
//(bridge_state_policy, "BSS") — unless `with_nft` is False (the missing-NFT
//test). The cpo_root is a decoy trie holding t_peg_in_utxo_id under a wrong
//value, so a swapped-field read fails `has` (spec [LIB-1]).
fn t_bridge_state_ref_input(spi_root: ByteArray, with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base
        |> assets.add(t_bridge_state_policy, constants.bridge_state_asset_name, 1)
    } else {
      base
    }
  let decoy_cpo_root =
    mpf.insert(mpf.empty, t_peg_in_utxo_id, "decoy", []) |> mpf.root
  Input {
    output_reference: OutputReference {
      transaction_id: #"2222222222222222222222222222222222222222222222222222222222222222",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_bridge_state_policy),
        stake_credential: None,
      },
      value,
      datum: InlineDatum(
        BridgeState {
          spi_root,
          cpo_root: decoy_cpo_root,
          treasury_utxo_id: t_tm_input_0,
          treasury_amount: 5_000_000,
        },
      ),
      reference_script: None,
    },
  }
}

//The singleton a well-behaved TM Confirm produced: its spi_root maps this
//deposit to the sweeping TM's input-0 outpoint.
fn t_happy_singleton() -> Input {
  t_bridge_state_ref_input(t_swept_root(), True)
}

//Asset name of the PegInRequest NFT (= hash of the mint's consumed input_ref).
//Any 32-byte value works in the fixture: [CPI-8] reads whatever single token
//sits on the PIR input under the script's own policy and requires that burn.
const t_pir_nft_asset: ByteArray =
  #"5555555555555555555555555555555555555555555555555555555555555555"

fn t_pir_input(with_nft: Bool) -> Input {
  let base = assets.from_lovelace(2_000_000)
  let value =
    if with_nft {
      base |> assets.add(t_peg_in_script_hash, t_pir_nft_asset, 1)
    } else {
      base
    }
  Input {
    output_reference: OutputReference {
      transaction_id: #"3333333333333333333333333333333333333333333333333333333333333333",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_peg_in_script_hash),
        stake_credential: None,
      },
      value,
      datum: InlineDatum(
        PegInDatum {
          owner_auth: CardanoSignature { hash: #"dd33" },
          source_chain_peg_in_raw_tx: #"",
          source_chain_peg_in_raw_tx_index: 0,
          peg_in_utxo_id: t_peg_in_utxo_id,
          source_chain_treasury_utxo_id: #"",
          peg_in_amount: t_peg_in_amount,
          user_source_chain_pub_key: t_user_pub_key,
        },
      ),
      reference_script: None,
    },
  }
}

//One-field CPI trie datum, raw — utils.get_mpf_from_output reads field 0.
fn t_cpi_datum(root: ByteArray) -> Data {
  builtin.constr_data(0, [builtin.b_data(root)])
}

fn t_cpi_address() -> Address {
  Address {
    payment_credential: Script(t_cpi_policy),
    stake_credential: None,
  }
}

fn t_cpi_value() -> assets.Value {
  assets.from_lovelace(2_000_000)
    |> assets.add(t_cpi_policy, constants.completed_peg_ins_root_asset_name, 1)
}

//CPI trie input: the empty trie (this deposit not yet minted).
fn t_cpi_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4444444444444444444444444444444444444444444444444444444444444444",
      output_index: 0,
    },
    output: Output {
      address: t_cpi_address(),
      value: t_cpi_value(),
      datum: InlineDatum(t_cpi_datum(mpf.root(mpf.empty))),
      reference_script: None,
    },
  }
}

fn t_cpi_output(root: ByteArray) -> Output {
  Output {
    address: t_cpi_address(),
    value: t_cpi_value(),
    datum: InlineDatum(t_cpi_datum(root)),
    reference_script: None,
  }
}

fn t_fbtc_output(amount: Int) -> Output {
  Output {
    address: t_recipient(),
    value: assets.from_lovelace(2_000_000)
      |> assets.add(t_bridged_token_policy, t_bridged_token_asset, amount),
    datum: transaction.NoDatum,
    reference_script: None,
  }
}

fn t_fbtc_mint(minted_fbtc: Int) -> assets.Value {
  assets.from_asset(t_bridged_token_policy, t_bridged_token_asset, minted_fbtc)
}

//The well-formed mint field: the fBTC mint plus the [CPI-8] burn of the
//spent request's PegInRequest NFT.
fn t_happy_mint(minted_fbtc: Int) -> assets.Value {
  t_fbtc_mint(minted_fbtc)
    |> assets.add(t_peg_in_script_hash, t_pir_nft_asset, -1)
}

fn t_complete_with(
  pir: Input,
  singleton: Input,
  depositor_signature: ByteArray,
  cpi_output_root: ByteArray,
  mint: assets.Value,
) -> Bool {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [pir, t_cpi_input()],
      reference_inputs: [t_config_ref_input(), singleton],
      outputs: [t_fbtc_output(t_peg_in_amount), t_cpi_output(cpi_output_root)],
      mint,
    }
  peg_in_validator.withdraw(
    t_oracle_policy,
    t_config_policy,
    t_config_asset,
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: CompletePegIn {
        recipient: t_recipient(),
        fbtc_output_index: 0,
        depositor_signature,
        completed_peg_in_utxos_input_index: 1,
        completed_peg_in_utxos_output_index: 1,
        added_peg_in_to_completed_peg_ins_inclusion_proof: [],
        peg_in_in_completed_peg_ins_exclusion_proof: [],
        bridge_state_ref_input_index: 1,
        sweeping_tm_input_0: t_tm_input_0,
        peg_in_swept_membership_proof: [],
      },
    },
    Script(t_peg_in_script_hash),
    tx,
  )
}

fn t_complete(
  singleton: Input,
  depositor_signature: ByteArray,
  cpi_output_root: ByteArray,
  minted_fbtc: Int,
) -> Bool {
  t_complete_with(
    t_pir_input(True),
    singleton,
    depositor_signature,
    cpi_output_root,
    t_happy_mint(minted_fbtc),
  )
}

//spec [CPI-9]/[CPI-10]/[CPI-3]/[CPI-6]: singleton ref input whose spi_root
//holds (peg_in_utxo_id -> tm_input_0), a valid BIP-322 signature over the
//NEW (btc_txid-free) message, exact fBTC mint to the recipient, and the CPI
//trie advanced with tm_input_0 as the inserted value. Fails before the
//rev-5.4 implementation: the validator still demands a Confirmed TM
//reference input carrying the TM NFT.
test complete_peg_in_happy_path() {
  t_complete(t_happy_singleton(), t_sig_new, t_swept_root(), t_peg_in_amount)
}

//spec [CPI-9]: the singleton's spi_root is the empty trie — the deposit was
//never swept, so no membership proof exists and completion must fail.
test complete_rejects_unswept() fail {
  t_complete(
    t_bridge_state_ref_input(mpf.root(mpf.empty), True),
    t_sig_new,
    t_swept_root(),
    t_peg_in_amount,
  )
}

//spec [CPI-10]: the reference input at the singleton's address lacks the
//(bridge_state_policy, "BSS") NFT, so it cannot authenticate a BridgeState.
test complete_rejects_missing_singleton_nft() fail {
  t_complete(
    t_bridge_state_ref_input(t_swept_root(), False),
    t_sig_new,
    t_swept_root(),
    t_peg_in_amount,
  )
}

//spec [CPI-3] (revised): a genuine signature over the rev-5.1 digest — which
//still includes a btc_txid — must not authorize the completion. The message
//is now sha2_256(mint_tag ‖ peg_in_utxo_id ‖ recipient), nothing else.
test complete_rejects_old_message_signature() fail {
  t_complete(t_happy_singleton(), t_sig_old, t_swept_root(), t_peg_in_amount)
}

//spec [CPI-6]: total fBTC minted must equal peg_in_amount exactly. Only the
//mint is short here; the recipient output still shows the full amount.
test complete_rejects_partial_mint() fail {
  t_complete(
    t_happy_singleton(),
    t_sig_new,
    t_swept_root(),
    t_peg_in_amount - 1,
  )
}

//spec §The two deposit tries: the CPI trie must map peg_in_utxo_id to the
//sweeping TM's input-0 outpoint. Inserting peg_in_utxo_id as its own value
//(the rev-5.1 shape) must fail.
test complete_rejects_wrong_cpi_value() fail {
  let wrong_root =
    mpf.insert(mpf.empty, t_peg_in_utxo_id, t_peg_in_utxo_id, [])
      |> mpf.root
  t_complete(t_happy_singleton(), t_sig_new, wrong_root, t_peg_in_amount)
}

//spec [CPI-8]: the spent request must carry a PegInRequest NFT under the
//script's own policy. Without it the inline datum (amount, outpoint, key) is
//unauthenticated: anyone could park a hand-made PegInDatum at this address
//naming a genuinely swept outpoint and mint arbitrary fBTC.
test complete_rejects_missing_pir_nft() fail {
  t_complete_with(
    t_pir_input(False),
    t_happy_singleton(),
    t_sig_new,
    t_swept_root(),
    t_fbtc_mint(t_peg_in_amount),
  )
}

//spec [CPI-8]: the PegInRequest NFT must be burned. If it survived the spend
//it could later authenticate a forged datum at the script address.
test complete_rejects_unburned_pir_nft() fail {
  t_complete_with(
    t_pir_input(True),
    t_happy_singleton(),
    t_sig_new,
    t_swept_root(),
    t_fbtc_mint(t_peg_in_amount),
  )
}
