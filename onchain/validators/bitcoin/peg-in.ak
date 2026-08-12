use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/interval
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/bip322
use bifrost/bitcoin
use bifrost/constants
use bifrost/types/bridge_state.{BridgeState}
use bifrost/types/config
use bifrost/types/general.{CardanoSignature, ChainState}
use bifrost/types/peg_in.{
  Close, CompletePegIn, Duplicate, NeverSwept, PegInDatum, PegInMintRedeemer,
  PegInRequest, PegInWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, quantity_of, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
  find_input, placeholder,
}

// Domain-separation tag "BFR-mint-v1" for the depositor completion-signing message (BIP340
// practice; technical_documentation.md §"Complete peg-in"). Must equal binocular
// BifrostMessages.mintTag.
const mint_tag: ByteArray = #"4246522d6d696e742d7631"

//Grace period before a never-swept PegInRequest may be closed: 30 days in ms,
//mirroring peg_out_cancel_timeout_ms. spec §Close PegInRequest, [CLR-5].
pub const peg_in_close_timeout_ms: Int = 2_592_000_000

//Read the bridge state singleton from the reference input at `index`. Both the
//[CPI-9] completion and the [CLR-6] never-swept close read `spi_root` this way.
//
//spec [CPI-10]: the NFT (bridge_state_policy, "BSS") — not the address — is the
//trust anchor: it can only live under the gated singleton policy. The singleton
//is located by redeemer index rather than by scanning reference_inputs for the
//NFT: the scan costs O(reference_inputs) and, worse, would silently pick a
//different UTxO if one ever matched, whereas a wrong index traps.
//spec [LIB-1]: decode the datum as BridgeState and read its roots BY NAME,
//never by field position. spec [LIB-2]: never utils.get_mpf_from_output here —
//a blind field-0 read returns spi_root only by accident of the current field
//order, and would silently return the wrong root if it changed.
fn read_bridge_state(
  reference_inputs: List<Input>,
  index: Int,
  bridge_state_policy: PolicyId,
) -> BridgeState {
  let bridge_state_ref_input = utils.safe_list_at(reference_inputs, index)
  expect
    quantity_of(
      bridge_state_ref_input.output.value,
      bridge_state_policy,
      constants.bridge_state_asset_name,
    ) == 1
  expect InlineDatum(state_raw) = bridge_state_ref_input.output.datum
  //spec [LIB-1]: a TYPED decode, not a positional read. It checks the
  //constructor tag AND the exact arity, so `state.cpo_root` can never be
  //silently taken for its neighbour — the misread whose consequence is a
  //SUCCEEDING `mpf.miss`, i.e. cancelling a paid PegOutRequest.
  //
  //The exact arity is deliberate and it FREEZES the datum at four fields:
  //a fifth would trap this validator from the first Confirm that writes it,
  //and this script cannot be replaced without abandoning its state. That is
  //the documented trade ([LIB-3]) — `BridgeState` is not governance data, so
  //widening it is a protocol revision, not an append. Do NOT "relax" this to
  //positional getters to make room for a field: config.ak reads positionally
  //because its datum is MEANT to grow; this one is not.
  expect state: BridgeState = state_raw
  state
}

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
      // withdraw handler gates the burn: CompletePegIn requires it ([CPI-8]) and Close requires
      // it too ([CLR-10]). A burn tx need not reference an oracle / deposit, so it must not be
      // forced through the mint-time checks below.
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

        //spec [CLR-7]: the datum's `created` is pinned to the mint
        //transaction's validity upper bound, which must be finite. The Close
        //never-swept timeout ([CLR-5]) counts from `created`, so a forged
        //(earlier) `created` would let the owner close before the grace
        //period; the upper bound is the earliest time the chain can prove the
        //request did NOT already exist.
        expect interval.Finite(validity_upper_bound) =
          self.validity_range.upper_bound.bound_type
        let created_pinned =
          peg_in_request.expected_datum.created == validity_upper_bound
        and {
          is_input_ref_spent,
          peg_in_amount_positive,
          correct_asset_name,
          output_has_unique_token,
          output_has_correct_datum,
          block_header_included_in_source_chain,
          peg_in_request_tx_included_in_block_header,
          deposit_bound,
          created_pinned,
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
      Close { burnt_peg_in_nft_asset_name, proof } -> {
        expect Script(peg_in_policy_id) = credential
        expect InlineDatum(input_datum) = peg_in_input.output.datum
        expect datum: PegInDatum = input_datum
        //spec [CLR-9]: only the datum's owner_auth may close the request
        //(same authorizer pattern as peg-out Cancel).
        let close_authorized = authorize_action(
          create_auth(
            datum.owner_auth,
            self.inputs,
            self.reference_inputs,
            self.withdrawals,
            self.extra_signatories,
            self.mint,
          ),
        )
        //Two mutually exclusive proof branches, chosen by the redeemer.
        //[CLR-3]/[CLR-4] are withdrawn: no verifier script, no Bitcoin
        //witness parsing.
        let close_proven =
          when proof is {
            NeverSwept { bridge_state_ref_input_index, spi_exclusion_proof } -> {
              //spec [CLR-5]: the tx validity range must lie ENTIRELY after
              //created + peg_in_close_timeout_ms. Before that, a sweep (and
              //so a completion) may still happen.
              let timeout_elapsed = interval.is_entirely_after(
                self.validity_range,
                datum.created + peg_in_close_timeout_ms,
              )
              //The bridge state singleton as a reference input. See
              //read_bridge_state for [CPI-10]/[LIB-1]/[LIB-2]. spec [PAR-1]:
              //its policy comes from Config at runtime.
              let state =
                read_bridge_state(
                  self.reference_inputs,
                  bridge_state_ref_input_index,
                  config.get_bridge_state_policy(config_fields),
                )
              //spec [CLR-6]: the deposit is absent from the singleton's
              //spi_root — it was never swept, so it can never complete.
              let never_swept = mpf.miss(
                mpf.from_root(state.spi_root),
                datum.peg_in_utxo_id,
                spi_exclusion_proof,
              )
              timeout_elapsed && never_swept
            }
            Duplicate {
              completed_peg_ins_ref_input_index,
              sweeping_tm_input_0,
              cpi_membership_proof,
            } -> {
              //spec [CLR-8]: the CPI trie (a reference input authenticated by
              //the NFT (completed_peg_ins_policy, "CPI")) already maps
              //peg_in_utxo_id to the sweeping TM's input-0 outpoint (spec
              //§The two deposit tries): the deposit already minted, so this
              //duplicate request can never complete. NO timeout.
              let cpi_ref_input = utils.safe_list_at(
                self.reference_inputs,
                completed_peg_ins_ref_input_index,
              )
              expect
                quantity_of(
                  cpi_ref_input.output.value,
                  completed_peg_ins_merkle_tree_policy_id,
                  completed_peg_ins_merkle_tree_asset_name,
                ) == 1
              mpf.has(
                utils.get_mpf_from_output(cpi_ref_input.output),
                datum.peg_in_utxo_id,
                sweeping_tm_input_0,
                cpi_membership_proof,
              )
            }
          }
        //Input must contain a PegIn nft
        let peg_in_nft_in_input = quantity_of(
          peg_in_input.output.value,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == 1
        //spec [CLR-10]: the input PegIn nft must be burnt — the request must
        //not outlive the close.
        let peg_in_nft_burnt = quantity_of(
          self.mint,
          peg_in_policy_id,
          burnt_peg_in_nft_asset_name,
        ) == -1
        //spec [CLR-11]: a close must never mint or burn the bridged token:
        //this is what keeps bridged_token's presence-only delegation sound (a
        //Close can not smuggle an unconstrained fSAT mint).
        let no_bridged_token_mint =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
        and {
          close_authorized,
          close_proven,
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

        // 1. Reference the bridge state singleton. See read_bridge_state for
        //    [CPI-10]/[LIB-1]/[LIB-2]. spec [PAR-1]: its policy comes from the
        //    Config reference input at runtime, not a validator parameter.
        //spec [PAR-1]
        let state =
          read_bridge_state(
            self.reference_inputs,
            bridge_state_ref_input_index,
            config.get_bridge_state_policy(config_fields),
          )

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

//The PIR owner's authorization key hash (owner_auth = CardanoSignature).
const t_owner_hash: ByteArray = #"dd33"

//An arbitrary POSIX-ms creation time. Close tests offset validity ranges
//relative to it + peg_in_close_timeout_ms.
const t_created: Int = 1_700_000_000_000

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

//The rev-5.4 fifteen-field Config datum (spec §Config datum), raw on
//purpose:
//readers use positional getters, so the fixture mirrors the wire encoding.
fn t_config_datum_data() -> Data {
  let update_auth_data: Data = Some(CardanoSignature { hash: #"aadd" })
  //params (ConfigDatum field 1): schedule, fee_rate_sat_per_vb, per_pegout_fee,
  //min_peg_out_fbtc, base_ban_duration_ms, max_faults_before_permanent,
  //max_validity_window_ms, federation_csv_blocks. The schedule slot is a dummy
  //Int: no validator reads it, and a full ScheduleParams here would freeze its
  //shape into this fixture for no gain.
  let params_data: Data =
    builtin.constr_data(
      0,
      [
        builtin.i_data(0),
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
      builtin.b_data(t_bridged_token_policy),
      builtin.b_data(t_cpi_policy),
      builtin.b_data(t_bridge_state_policy),
      //tm_script_hash, spec [CFG-2]: no on-chain reader
      builtin.b_data(#"aa333333333333333333333333333333333333333333333333333333"),
      builtin.b_data(t_peg_in_script_hash),
      builtin.b_data(#"aa555555555555555555555555555555555555555555555555555555"),
      //Federation identity, indexes 8-11 (spec §Config datum).
      builtin.b_data(#"aabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
      builtin.b_data(#"aacccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
      builtin.b_data(#"aadddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
      //y_federation, spec [UY-5]: read on-chain by treasury.ak only
      builtin.b_data(#"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"),
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

//A singleton whose spi_root is the empty trie: this deposit was never swept,
//so peg_in_utxo_id is provably absent with the empty proof.
fn t_unswept_singleton() -> Input {
  t_bridge_state_ref_input(mpf.root(mpf.empty), True)
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
          owner_auth: CardanoSignature { hash: t_owner_hash },
          source_chain_peg_in_raw_tx: #"",
          source_chain_peg_in_raw_tx_index: 0,
          peg_in_utxo_id: t_peg_in_utxo_id,
          peg_in_amount: t_peg_in_amount,
          user_source_chain_pub_key: t_user_pub_key,
          created: t_created,
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
    t_unswept_singleton(),
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

//----------------------------------------------------------------------------
// Tests – Close PegInRequest via SPI/CPI MPF proofs (spec §Close
// PegInRequest: [CLR-5] to [CLR-11]; [CLR-3]/[CLR-4] withdrawn)
//----------------------------------------------------------------------------

//The CPI trie as a REFERENCE input, authenticated by the NFT
//(completed_peg_ins_policy, "CPI"). spec [CLR-8].
fn t_cpi_ref_input(root: ByteArray) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"8888888888888888888888888888888888888888888888888888888888888888",
      output_index: 0,
    },
    output: t_cpi_output(root),
  }
}

//A look-alike CPI trie reference input WITHOUT the authenticating NFT
//(completed_peg_ins_policy, "CPI"): same address, same datum shape, no
//token. Anyone can create such a UTxO, so [CLR-8] must reject it.
fn t_cpi_ref_input_no_nft(root: ByteArray) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"8888888888888888888888888888888888888888888888888888888888888888",
      output_index: 0,
    },
    output: Output {
      address: t_cpi_address(),
      value: assets.from_lovelace(2_000_000),
      datum: InlineDatum(t_cpi_datum(root)),
      reference_script: None,
    },
  }
}

//The [CLR-10] burn of the spent request's PIR NFT, and nothing else.
fn t_pir_burn() -> assets.Value {
  assets.from_asset(t_peg_in_script_hash, t_pir_nft_asset, -1)
}

fn t_close_with(
  pir: Input,
  proof_ref_input: Input,
  proof: peg_in.ClosePegInProof,
  mint: assets.Value,
  extra_signatories: List<ByteArray>,
  validity_range: ValidityRange,
) -> Bool {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [pir],
      reference_inputs: [t_config_ref_input(), proof_ref_input],
      mint,
      extra_signatories,
      validity_range,
    }
  peg_in_validator.withdraw(
    t_oracle_policy,
    t_config_policy,
    t_config_asset,
    PegInWithdrawRedeemer {
      config_ref_input_index: 0,
      action_type: Close { burnt_peg_in_nft_asset_name: t_pir_nft_asset, proof },
    },
    Script(t_peg_in_script_hash),
    tx,
  )
}

//The never-swept branch redeemer: singleton at reference input 1, empty
//exclusion proof (spi_root is the empty trie in the happy fixture).
fn t_never_swept_proof() -> peg_in.ClosePegInProof {
  NeverSwept { bridge_state_ref_input_index: 1, spi_exclusion_proof: [] }
}

//The duplicate branch redeemer: CPI trie at reference input 1, membership of
//(peg_in_utxo_id -> sweeping TM input-0 outpoint) with the empty proof
//(single-leaf trie).
fn t_duplicate_proof() -> peg_in.ClosePegInProof {
  Duplicate {
    completed_peg_ins_ref_input_index: 1,
    sweeping_tm_input_0: t_tm_input_0,
    cpi_membership_proof: [],
  }
}

//spec [CLR-5]/[CLR-6]/[CLR-9]/[CLR-10]/[CLR-11]: validity entirely after
//created + peg_in_close_timeout_ms, mpf.miss against the singleton's
//spi_root (empty trie: never swept), PIR NFT burned, owner signed, no fBTC
//moved. Fails before the implementation: the branch is the transitional
//hard False.
test close_never_swept_happy() {
  t_close_with(
    t_pir_input(True),
    t_unswept_singleton(),
    t_never_swept_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.after(t_created + peg_in_close_timeout_ms + 1),
  )
}

//spec [CLR-5]: the validity range must lie ENTIRELY after created + timeout.
//A lower bound equal to the boundary exactly is not entirely after it.
test close_rejects_timeout_boundary() fail {
  t_close_with(
    t_pir_input(True),
    t_unswept_singleton(),
    t_never_swept_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.after(t_created + peg_in_close_timeout_ms),
  )
}

//spec [CLR-6]: the singleton's spi_root CONTAINS peg_in_utxo_id (the deposit
//was swept), so no exclusion proof exists and the never-swept close must
//fail even though the timeout has elapsed.
test close_rejects_swept() fail {
  t_close_with(
    t_pir_input(True),
    t_happy_singleton(),
    t_never_swept_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.after(t_created + peg_in_close_timeout_ms + 1),
  )
}

//spec [CLR-8]: the CPI trie maps peg_in_utxo_id to the sweeping TM's input-0
//outpoint – the deposit already minted, so this duplicate request closes with
//NO timeout: the validity range lies entirely BEFORE created + timeout.
//Fails before the implementation: the branch is the transitional hard False.
test close_duplicate_happy() {
  t_close_with(
    t_pir_input(True),
    t_cpi_ref_input(t_swept_root()),
    t_duplicate_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.between(t_created, t_created + 1_000),
  )
}

//spec [CLR-8]: the CPI trie is EMPTY – the deposit never minted, so no
//membership proof exists and the duplicate close must fail even though the
//redeemer claims one. The Duplicate branch has no timeout, so mpf.has is
//its load-bearing gate.
test close_rejects_no_cpi_membership() fail {
  t_close_with(
    t_pir_input(True),
    t_cpi_ref_input(mpf.root(mpf.empty)),
    t_duplicate_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.between(t_created, t_created + 1_000),
  )
}

//spec [CLR-8]: the CPI trie reference input must carry the NFT
//(completed_peg_ins_policy, "CPI"). A look-alike UTxO with the right datum
//but no NFT is attacker-forgeable and must be rejected.
test close_rejects_missing_cpi_nft() fail {
  t_close_with(
    t_pir_input(True),
    t_cpi_ref_input_no_nft(t_swept_root()),
    t_duplicate_proof(),
    t_pir_burn(),
    [t_owner_hash],
    interval.between(t_created, t_created + 1_000),
  )
}

//spec [CLR-9]: a third party (not the datum's owner_auth) cannot close
//someone else's request, even a provably dead one.
test close_rejects_unauthorized() fail {
  t_close_with(
    t_pir_input(True),
    t_unswept_singleton(),
    t_never_swept_proof(),
    t_pir_burn(),
    [#"ee999999999999999999999999999999999999999999999999999999"],
    interval.after(t_created + peg_in_close_timeout_ms + 1),
  )
}

//spec [CLR-10]: the PIR NFT must be burned (mint == -1 under the peg-in
//policy). Here the mint field is empty, so the NFT would survive the spend.
test close_rejects_nft_not_burned() fail {
  t_close_with(
    t_pir_input(True),
    t_unswept_singleton(),
    t_never_swept_proof(),
    assets.zero,
    [t_owner_hash],
    interval.after(t_created + peg_in_close_timeout_ms + 1),
  )
}

//spec [CLR-11]: a close must mint and burn NO fBTC – this is what keeps
//bridged_token's presence-only delegation sound.
test close_rejects_fbtc_minted() fail {
  t_close_with(
    t_pir_input(True),
    t_unswept_singleton(),
    t_never_swept_proof(),
    t_pir_burn()
      |> assets.add(t_bridged_token_policy, t_bridged_token_asset, 1),
    [t_owner_hash],
    interval.after(t_created + peg_in_close_timeout_ms + 1),
  )
}

//----------------------------------------------------------------------------
// Tests – mint pins `created` (spec [CLR-7])
//----------------------------------------------------------------------------

//A hand-built non-witness peg-in deposit tx (copied from
//lib/bifrost/bitcoin.ak's sample_deposit_tx, private there): vout 0 = P2TR
//(0x5120…) worth 100000 sat, vout 1 = BFR OP_RETURN committing refund key
//dd*32 and depositor auth key cc*32.
const t_mint_deposit_tx: ByteArray =
  #"020000000100000000000000000000000000000000000000000000000000000000000000000000000000ffffffff02a086010000000000225120bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0000000000000000456a43424652ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000"

//The depositor auth key the deposit's OP_RETURN beacon commits.
const t_mint_xonly: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_zero32: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

fn t_mint_deposit_txid() -> ByteArray {
  utils.bitcoin_hash(t_mint_deposit_tx)
}

//An 80-byte block header: version(4) ‖ prev(32) ‖ merkle_root(32) ‖
//time+bits+nonce(12). The deposit is the only proven tx (index 0, empty
//proof), so the merkle root IS its txid.
fn t_mint_block_header() -> ByteArray {
  #"00000000"
    |> bytearray.concat(t_zero32)
    |> bytearray.concat(t_mint_deposit_txid())
    |> bytearray.concat(#"000000000000000000000000")
}

//The Binocular oracle as a reference input: its confirmed_blocks_root is the
//single-leaf trie (block_hash -> block_hash).
fn t_oracle_ref_input() -> Input {
  let block_hash = utils.bitcoin_hash(t_mint_block_header())
  let root = mpf.insert(mpf.empty, block_hash, block_hash, []) |> mpf.root
  Input {
    output_reference: OutputReference {
      transaction_id: #"9999999999999999999999999999999999999999999999999999999999999999",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: Script(t_oracle_policy),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_oracle_policy, #"", 1),
      datum: InlineDatum(
        ChainState {
          confirmed_blocks_root: root,
          ctx: builtin.i_data(0),
          pending: builtin.i_data(0),
        },
      ),
      reference_script: None,
    },
  }
}

//A fully valid PIR mint – spent input_ref, oracle inclusion proofs, deposit
//binding, NFT + datum on the script output – whose validity range tops out
//at t_created. Only the datum's `created` varies, so the pair of tests below
//isolates the [CLR-7] pin.
fn t_mint_with_created(created: Int) -> Bool {
  let input_ref =
    OutputReference {
      transaction_id: #"7777777777777777777777777777777777777777777777777777777777777777",
      output_index: 0,
    }
  let funding_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: Address {
          payment_credential: VerificationKey(t_owner_hash),
          stake_credential: None,
        },
        value: assets.from_lovelace(10_000_000),
        datum: transaction.NoDatum,
        reference_script: None,
      },
    }
  let pir_asset_name = utils.hash_output_ref(input_ref)
  let expected_datum =
    PegInDatum {
      owner_auth: CardanoSignature { hash: t_owner_hash },
      source_chain_peg_in_raw_tx: t_mint_deposit_tx,
      source_chain_peg_in_raw_tx_index: 0,
      peg_in_utxo_id: bytearray.concat(t_mint_deposit_txid(), #"00000000"),
      peg_in_amount: 100_000,
      user_source_chain_pub_key: t_mint_xonly,
      created,
    }
  let peg_in_request =
    PegInRequest {
      expected_datum,
      block_header: t_mint_block_header(),
      block_header_in_source_chain_inclusion_proof: [],
      tx_in_block_header_inclusion_proof: [],
    }
  let pir_output =
    Output {
      address: Address {
        payment_credential: Script(t_peg_in_script_hash),
        stake_credential: None,
      },
      value: assets.from_lovelace(2_000_000)
        |> assets.add(t_peg_in_script_hash, pir_asset_name, 1),
      datum: InlineDatum(expected_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [funding_input],
      reference_inputs: [t_oracle_ref_input()],
      outputs: [pir_output],
      mint: assets.from_asset(t_peg_in_script_hash, pir_asset_name, 1),
      validity_range: interval.between(t_created - 3_600_000, t_created),
    }
  peg_in_validator.mint(
    t_oracle_policy,
    t_config_policy,
    t_config_asset,
    PegInMintRedeemer { input_ref, new_peg_in_request: peg_in_request },
    t_peg_in_script_hash,
    tx,
  )
}

//spec [CLR-7]: the mint handler must pin the datum's `created` to the mint
//transaction's validity upper bound. created = 0 while the validity range
//tops out at t_created, so the mint must be rejected. Fails before the
//implementation: the handler has no created check and accepts.
test mint_pins_created() fail {
  t_mint_with_created(0)
}

//spec [CLR-7], accepting case: created equal to the validity upper bound
//passes the whole mint handler. This is the handler's only positive test –
//it pins every other mint check (oracle proofs, deposit binding, NFT +
//datum) in the accepting direction too.
test mint_accepts_pinned_created() {
  t_mint_with_created(t_created)
}
