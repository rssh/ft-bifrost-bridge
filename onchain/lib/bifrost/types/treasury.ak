// Treasury state datum (normative — technical_documentation.md §Treasury state
// UTxO). Rev 5.5 cut it to two fields:
//   #0 bifrost_identity_root  — MPF root of active bifrost_id_pk -> pool_id
//   #1 current_spos_frost_key — Y_51 after the first DKG; Y_federation until then
//
// Gone in rev 5.5:
// - last_reset_tm_txid: inert since its only writer, the FederationReset
//   branch, was withdrawn ([UY-7], [UY-8]).
// - y_federation, federation_csv_blocks: instance configuration, not state.
//   Nothing here ever rotated them. They live in the Config datum now, where an
//   ordinary Update rotates them.
//
// spec [TSY-1]: exactly two fields, decoded as a type and read by name per
// [LIB-1]. Only ConfigDatum must stay append-extensible, because every contract
// is parameterized by the Config NFT and so the Config alone cannot be swapped.
// This UTxO sits behind its own NFT, and replacing it is a bootstrap.
pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  current_spos_frost_key: ByteArray,
}

// No mint redeemer. The one-shot outpoint is a validator parameter and the
// asset name is a constant, so the mint has nothing left to be told.

// Neither branch names the value it writes. The continuing output's datum is
// the only source of truth for the new field, and the redeemer says just enough
// to authorize the write:
//
// - `new_bifrost_identity_root` was never constrained here. spos-registry.ak
//   owns that value, through the [REG-5] MPF proof.
// - `new_spos_frost_key` was pinned to the output datum by an equality check,
//   so it could only ever restate it. Reading it from the datum is safe because
//   `rotation_sig_msg` commits to it: swapping the datum's key invalidates the
//   signature.
//
// Both fields were 32 bytes of witness paid for on every rotation, and one more
// pair of values that had to agree.
pub type TreasurySpendRedeemer {
  // Registry-coupled root update (Register / Deregister). Only
  // bifrost_identity_root may change. spec [TSY-12]: the registry policy id
  // comes from the Config datum, never from a parameter — a parameter here
  // would recreate the cycle that made the registry-side pin impossible.
  RegistryUpdate { config_ref_input_index: Int }
  // Update-Y (DKG key rotation): only current_spos_frost_key changes,
  // authorized by a BIP340 signature over
  //   sha2_256("bifrost-update-y" ++ spent_outpoint(36B: txid ++ vout LE)
  //            ++ epoch(8B BE) ++ new_spos_frost_key(32B)),
  // where new_spos_frost_key is read from the CONTINUING output's datum.
  // The signer is the OUTGOING datum's current_spos_frost_key, or — spec
  // [UY-5] — the Config's y_federation, the federation's standing co-authority,
  // which replaces the withdrawn FederationReset branch. The federation MAY
  // name any key (spec: [UY-6] WITHDRAWN).
  // Submission is permissionless: the signature is the authorization and the
  // message commits to the spent outpoint, so it cannot be replayed.
  UpdateY { epoch: Int, signature: ByteArray, config_ref_input_index: Int }
  // Instance teardown. spec [TSY-19]: gated on the Config NFT burn, and on
  // nothing else. Burning the Config NFT necessarily spends the Config UTxO,
  // which runs config.ak's own Retire branch under update_auth, so governance
  // authorization is inherited rather than duplicated.
  Retire
}
