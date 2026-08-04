use aiken/merkle_patricia_forestry as mpf
use bifrost/types/general.{AuthorizationMethod}

pub type PegOutDatum {
  //Auth that can then spend this utxo
  owner_auth: AuthorizationMethod,
  //The scriptPubKey that receives the pegged-out BTC on the source chain
  source_chain_destination_address: ByteArray,
  //This peg-out's protocol fee (satoshi), pinned at lock time from the
  //Config floor (field 13). The TM pays amount − this fee; Complete binds
  //against THIS field, never a current on-chain value.
  per_pegout_fee: Int,
  //POSIX ms creation time, set by the requester. Gates Cancel (created +
  //peg_out_cancel_timeout_ms). Backdating is harmless: the SPO TM builder
  //only fulfills fresh requests (freshness margin), so a backdated POR can
  //only be cancelled — refunding the requester's own fBTC.
  created: Int,
}

pub type PegOutActionType {
  //Prove the completed-peg-outs trie maps this POR id to
  //dest_spk ++ amount_le8 and burn the locked fBTC.
  CompletePegOut { membership_proof: mpf.Proof }
  //After the timeout, prove this POR id is NOT in the trie and reclaim.
  Cancel { exclusion_proof: mpf.Proof }
}

pub type PegOutWithdrawRedeemer {
  config_ref_input_index: Int,
  completed_peg_outs_ref_input_index: Int,
  action_type: PegOutActionType,
}
