use aiken/merkle_patricia_forestry as mpf
use bifrost/types/general.{AuthorizationMethod}
use cardano/address.{Address}
use cardano/assets.{AssetName}
use cardano/transaction.{OutputReference}

pub type PegInDatum {
  //Auth that can then spend this utxo
  owner_auth: AuthorizationMethod,
  //PegInRequest tx to be parsed
  source_chain_peg_in_raw_tx: ByteArray,
  //PegInRequest tx index in the block
  source_chain_peg_in_raw_tx_index: Int,
  //Utxo ID of the PegIn in the Taproot address
  peg_in_utxo_id: ByteArray,
  //The utxo id of the Treasury on the source chain
  source_chain_treasury_utxo_id: ByteArray,
  //Amount of tokens to PegIn
  peg_in_amount: Int,
  //Pubkey used by the user to start the PegIn on the source chain
  user_source_chain_pub_key: ByteArray,
}

pub type PegInRequest {
  expected_datum: PegInDatum,
  //The block header containing the PegInRequests tx
  block_header: ByteArray,
  //Proof that the passed block header belongs to the source chain
  block_header_in_source_chain_inclusion_proof: mpf.Proof,
  //Proof that the PegInRequest belongs to the block header
  tx_in_block_header_inclusion_proof: List<ByteArray>,
}

pub type PegInMintRedeemer {
  //Input spent during the minting (= creation of the PegInRequests)
  input_ref: OutputReference,
  //One or more PegInRequests that must be created on Cardano
  new_peg_in_request: PegInRequest,
}

pub type ActionType {
  // Close a peg-in request via its owner_auth. NOTE: a fully spec-faithful peg-in cancellation
  // (F4/F5: the creator closes the PIR after the depositor reclaims the BTC on the Bitcoin side via
  // the Taproot CSV refund leaf, gated on a refund-script witness proof) is part of the unbuilt
  // failure-mode milestone — see documentation/{technical_documentation,formal_verification}.md.
  Cancel { burnt_peg_in_nft_asset_name: AssetName }
  // Rev 5.4: completion proves the sweep against the bridge state singleton, referenced by index
  // and authenticated by the NFT (bridge_state_policy, "BSS") — no Confirmed TM record exists any
  // more. spec [CPI-9]: the singleton's spi_root maps peg_in_utxo_id to the sweeping TM's input-0
  // outpoint. Depositor authorization is embedded (the former `owner_auth` withdraw delegation to
  // binocular's PegInDepositorAuthValidator is gone): a BIP-322 keypath signature over
  // sha2_256("BFR-mint-v1" ‖ peg_in_utxo_id ‖ recipient) with the datum's
  // `user_source_chain_pub_key`, plus recipient-binding of the minted fBTC. spec [CPI-3]
  CompletePegIn {
    //Depositor-chosen fBTC destination; bound into both the signed message and the fBTC output
    recipient: Address,
    //Index of the output paying `peg_in_amount` fBTC to `recipient`
    fbtc_output_index: Int,
    //Depositor's BIP340 Schnorr signature authorizing this recipient + TM
    depositor_signature: ByteArray,
    //Index of the input containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_input_index: Int,
    //Index of the output containing the completed_peg_ins merkle tree
    completed_peg_in_utxos_output_index: Int,
    //Inclusion proof to insert the newly completed PegIn
    added_peg_in_to_completed_peg_ins_inclusion_proof: mpf.Proof,
    //Proof that the PegIn is not yet included in the merkle tree of completed PegIns
    peg_in_in_completed_peg_ins_exclusion_proof: mpf.Proof,
    //Index of the bridge state singleton reference input, authenticated by the
    //NFT (bridge_state_policy, "BSS"). spec [CPI-10]
    bridge_state_ref_input_index: Int,
    //The sweeping TM's input-0 outpoint, 36 bytes: the SPI trie value for
    //peg_in_utxo_id, and the value the CPI trie insert records
    //(spec §The two deposit tries)
    sweeping_tm_input_0: ByteArray,
    //Membership proof of (peg_in_utxo_id -> sweeping_tm_input_0) in the
    //singleton's spi_root. spec [CPI-9]
    peg_in_swept_membership_proof: mpf.Proof,
  }
}

pub type PegInWithdrawRedeemer {
  config_ref_input_index: Int,
  //Type of action with the relative additional data
  action_type: ActionType,
}
