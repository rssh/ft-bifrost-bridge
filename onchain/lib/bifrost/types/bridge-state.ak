//BridgeState is the datum of the bridge state singleton UTxO
//(spec §BridgeState, the singleton datum).
//
//The datum is a Plutus Constr, so field order is consensus-visible: the
//fields sit at Constr indices 0..3. spec [LIB-3]: a new field MUST be
//appended, never inserted.
//
//LOCKSTEP: the Scalus TM validator in binocular
//(watchtower/TreasuryMovementValidator.scala) writes this datum at Confirm.
//The two definitions MUST move in lockstep.
pub type BridgeState {
  //Swept peg-ins root. Attested by the TM's commitment output, first root.
  spi_root: ByteArray,
  //Completed peg-outs root. Attested by the TM's commitment output,
  //second root.
  cpo_root: ByteArray,
  //The current treasury UTxO on Bitcoin: btc_txid ++ 00000000. The next TM
  //must spend it as its input 0, which [CTM-18] enforces.
  treasury_utxo_id: ByteArray,
  //Its satoshi amount.
  treasury_amount: Int,
}
