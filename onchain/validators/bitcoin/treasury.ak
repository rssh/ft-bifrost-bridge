use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/merkle_patricia_forestry as mpf
use aiken/option
use aiken/primitive/bytearray
use bifrost/types/treasury.{
  RegistryUpdate, TreasuryDatum, TreasuryMintRedeemer, TreasurySpendRedeemer,
  UpdateY,
}
use bifrost/utils
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, flatten, tokens, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input, placeholder,
}

// The domain-separated preimage a key rotation signs. One governance action
// remains ("bifrost-update-y", the Update-Y rotation; the reset tag died with
// the FederationReset branch, spec [UY-7]/[UY-8] WITHDRAWN). `tag` stays a
// parameter so heimdall's signer and this verifier agree byte-for-byte (see
// technical_documentation.md §Update-Y).
fn rotation_sig_msg(
  tag: ByteArray,
  own_ref: OutputReference,
  epoch: Int,
  new_key: ByteArray,
) -> ByteArray {
  crypto.sha2_256(
    tag
      |> bytearray.concat(own_ref.transaction_id)
      |> bytearray.concat(bytearray.from_int_little_endian(own_ref.output_index, 4))
      |> bytearray.concat(bytearray.from_int_big_endian(epoch, 8))
      |> bytearray.concat(new_key),
  )
}

// spec [PRE-1]: treasury.ak MUST NOT take tm_nft_policy_id. With the
// FederationReset branch removed it reads nothing the bridge owns, so its only
// parameter is registry_policy_id. (A compile parameter here would have broken
// permanently on any TM validator redeploy — this script's state UTxO can
// never move.)
validator treasury_info(registry_policy_id: PolicyId) {
  mint(redeemer: TreasuryMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let input_ref_hash = utils.hash_output_ref(redeemer.input_ref)
    let is_input_ref_spent =
      option.is_some(find_input(self.inputs, redeemer.input_ref))

    expect [treasury_output] =
      list.filter(
        self.outputs,
        fn(output) { output.address.payment_credential == Script(policy_id) },
      )

    //Minted tokens from this policy id must be only 1 and with quantity 1
    expect [Pair(_this_token_asset_name, 1)] =
      dict.to_pairs(tokens(self.mint, policy_id))

    //AssetName must be correct
    expect [(this_token_policy_id, this_token_asset_name, 1)] =
      flatten(without_lovelace(treasury_output.value))
    let only_minted_token_is_correctly_in_output = and {
        this_token_policy_id == policy_id,
        this_token_asset_name == input_ref_hash,
      }

    //Output must contain proper InlineDatum
    let output_has_correct_datum =
      treasury_output.datum == InlineDatum(
        TreasuryDatum {
          bifrost_identity_root: mpf.root(mpf.empty),
          current_spos_frost_key: redeemer.current_spos_frost_key,
          y_federation: redeemer.y_federation,
          federation_csv_blocks: redeemer.federation_csv_blocks,
          // Retired field (its FederationReset writer is withdrawn, spec
          // [UY-7]/[UY-8]); always empty.
          last_reset_tm_txid: #"",
        },
      )

    //Output with the minted token must go to this script
    let output_goes_to_this_script =
      treasury_output.address == Address {
        payment_credential: Script(policy_id),
        stake_credential: None,
      }

    and {
      is_input_ref_spent,
      only_minted_token_is_correctly_in_output,
      output_has_correct_datum,
      output_goes_to_this_script,
    }
  }

  spend(
    datum: Option<TreasuryDatum>,
    redeemer: TreasurySpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(own_input) = find_input(self.inputs, own_ref)
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Pair(own_asset_name, 1) =
      utils.get_singleton_asset_with_policy(own_input.output.value, own_hash)

    let continued_treasury_output =
      utils.find_singleton_asset_output_at_script(
        self.outputs,
        own_hash,
        own_hash,
        own_asset_name,
      )

    expect Some(in_datum) = datum

    // The Treasury state NFT, the whole value, and the script address always
    // carry over unchanged; only the datum differs per branch. Every branch
    // rewrites the datum with a record-update spread off `in_datum`, so any
    // field it does not name is preserved verbatim (this is what enforces the
    // field-permission matrix — see technical_documentation.md §Treasury state
    // UTxO).
    let carries_over = and {
        own_input.output.value == continued_treasury_output.value,
        own_input.output.address == continued_treasury_output.address,
      }

    when redeemer is {
      RegistryUpdate { new_bifrost_identity_root } -> and {
          carries_over,
          // A registry token must move in the same tx (Register / Deregister).
          utils.quantity_of_policy_id(self.mint, registry_policy_id) != 0,
          // Only bifrost_identity_root changes; current_spos_frost_key and the
          // rest are preserved here, no longer relying on spos-registry.ak's pin.
          continued_treasury_output.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              bifrost_identity_root: new_bifrost_identity_root,
            },
          ),
        }
      UpdateY { new_spos_frost_key, epoch, signature } -> and {
          carries_over,
          // The new key is a 32-byte x-only point (point-validity is the roster's
          // responsibility — it can only harm the roster that signed it).
          bytearray.length(new_spos_frost_key) == 32,
          // Only current_spos_frost_key changes.
          continued_treasury_output.datum == InlineDatum(
            TreasuryDatum {
              ..in_datum,
              current_spos_frost_key: new_spos_frost_key,
            },
          ),
          // Who may sign the rotation:
          //  - The OUTGOING key authorizes its own succession. In Phase 1 the
          //    spent datum holds Y_federation, so the federation signs the first
          //    rotation; thereafter each outgoing roster hands off to the next.
          //  - spec [UY-5]: OR the federation (BIP340 under the spent datum's
          //    y_federation) — its standing co-authority, which is the whole
          //    dead-roster recovery (it replaces the withdrawn FederationReset
          //    branch). spec [UY-6] WITHDRAWN: the federation MAY name any key.
          {
            let msg =
              rotation_sig_msg(
                "bifrost-update-y",
                own_ref,
                epoch,
                new_spos_frost_key,
              )
            or {
              crypto.verify_schnorr_signature(
                in_datum.current_spos_frost_key,
                msg,
                signature,
              ),
              crypto.verify_schnorr_signature(
                in_datum.y_federation,
                msg,
                signature,
              ),
            }
          },
        }
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

//----------------------------------------------------------------------------
// Tests (spend branches — N10a: contradiction fix + Update-Y key rotation)
//----------------------------------------------------------------------------

const t_own_hash: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const t_registry_policy: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const t_asset_name: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// Federation fields (preserved by the RegistryUpdate / UpdateY branches).
// t_yfed = x-only of secret 3, so the [UY-5] federation-signed Update-Y test
// can sign under it.
const t_yfed: ByteArray =
  #"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

const t_csv: Int = 144

const t_root0: ByteArray =
  #"0000000000000000000000000000000000000000000000000000000000000000"

const t_root1: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

// Update-Y BIP340 vector (generated by the BIP340 reference impl; the signed
// message is sha2_256("bifrost-update-y" ++ txid ++ vout LE(4) ++ epoch BE(8)
// ++ new_key) with the values below). t_cur_key is the x-only generator point
// (secret key = 1), which signs the rotation to t_new_key.
const t_cur_key: ByteArray =
  #"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

const t_new_key: ByteArray =
  #"abababababababababababababababababababababababababababababababab"

const t_updatey_txid: ByteArray =
  #"2222222222222222222222222222222222222222222222222222222222222222"

const t_updatey_epoch: Int = 7

const t_updatey_sig: ByteArray =
  #"21e3f8a17eac410867d72aea6a9089001153682a481861188527008e698c8d857e3454db7e2e413f0ae8a2aadedcc4d5f33934b6f5e066d9202cb78a591dcd21"

// spec [UY-5]: the SAME Update-Y message as t_updatey_sig, signed by the
// FEDERATION key instead (t_yfed's secret, 3). Generated by the BIP340
// reference impl with zeroed aux randomness.
const t_updatey_fed_sig: ByteArray =
  #"c5a6acf9ad7895ef37f63bdca615f21b73d2b08d0bdc244b36d53abb63cab264252a857c22522daebb7deec35b2066d72f5dc678413a1ca7ce7a018340018d53"

fn t_datum(root: ByteArray, key: ByteArray) -> TreasuryDatum {
  TreasuryDatum {
    bifrost_identity_root: root,
    current_spos_frost_key: key,
    y_federation: t_yfed,
    federation_csv_blocks: t_csv,
    last_reset_tm_txid: #"",
  }
}

// The outpoint the Update-Y signature commits to; reused as the spent treasury
// input for every test so find_input resolves and the message matches.
fn t_own_ref() -> OutputReference {
  OutputReference { transaction_id: t_updatey_txid, output_index: 0 }
}

fn t_treasury_value() -> assets.Value {
  assets.from_lovelace(2_000_000) |> assets.add(t_own_hash, t_asset_name, 1)
}

fn t_input(d: TreasuryDatum) -> Input {
  Input {
    output_reference: t_own_ref(),
    output: Output {
      address: Address {
        payment_credential: Script(t_own_hash),
        stake_credential: None,
      },
      value: t_treasury_value(),
      datum: InlineDatum(d),
      reference_script: None,
    },
  }
}

fn t_output(d: TreasuryDatum) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_own_hash),
      stake_credential: None,
    },
    value: t_treasury_value(),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

// A registry token moves — the Register/Deregister marker RegistryUpdate needs.
fn t_registry_mint() -> assets.Value {
  assets.from_asset(t_registry_policy, "reg-root", 1)
}

// RegistryUpdate: only bifrost_identity_root changes; key preserved. Passes.
test spend_registry_update_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      outputs: [t_output(d1)],
      mint: t_registry_mint(),
    }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// RegistryUpdate must NOT be able to rotate the key (the resolved contradiction):
// changing current_spos_frost_key on this branch is rejected.
test spend_registry_update_rejects_key_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [t_input(d0)],
      outputs: [t_output(d1)],
      mint: t_registry_mint(),
    }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// RegistryUpdate requires a registry-policy mint in the same tx.
test spend_registry_update_rejects_no_registry_mint() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_cur_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    RegistryUpdate { new_bifrost_identity_root: t_root1 },
    t_own_ref(),
    tx,
  )
}

// Update-Y: the outgoing key signs the rotation; only the key changes. Passes.
test spend_update_y_happy() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y with a valid signature but ALSO mutating bifrost_identity_root is
// rejected — only the key may change on this branch.
test spend_update_y_rejects_extra_field_change() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root1, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y with the wrong epoch breaks the signed message → signature fails.
test spend_update_y_rejects_wrong_epoch() fail {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch + 1,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// Update-Y signed by a key OTHER than the outgoing datum key is rejected.
test spend_update_y_rejects_wrong_signer() fail {
  let d0 = t_datum(t_root0, t_new_key)
  let d1 = t_datum(t_root0, t_cur_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_cur_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_sig,
    },
    t_own_ref(),
    tx,
  )
}

// spec [UY-5]: the FEDERATION signs the same Update-Y message under
// y_federation, and the rotation passes without the outgoing roster's key.
// This standing co-authority is the dead-roster recovery (it replaces the
// withdrawn FederationReset branch), and [UY-6] is withdrawn: the named key
// (t_new_key) is arbitrary, not restricted to y_federation itself.
test spend_update_y_federation_signed() {
  let d0 = t_datum(t_root0, t_cur_key)
  let d1 = t_datum(t_root0, t_new_key)
  let tx =
    Transaction { ..placeholder, inputs: [t_input(d0)], outputs: [t_output(d1)] }
  treasury_info.spend(
    t_registry_policy,
    Some(d0),
    UpdateY {
      new_spos_frost_key: t_new_key,
      epoch: t_updatey_epoch,
      signature: t_updatey_fed_sig,
    },
    t_own_ref(),
    tx,
  )
}
