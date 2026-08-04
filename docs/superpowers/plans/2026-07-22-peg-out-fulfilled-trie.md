# Peg-Out Fulfilled-Trie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the pinned-outpoint peg-out Complete/Cancel scheme with the
fulfilled-peg-outs MPF trie updated at TM Confirm, keyed by POR ids committed in
per-peg-out `"POR"` OP_RETURN markers of the TM Bitcoin transaction.
Spec: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`.

**Architecture:** Three repos change. Aiken (`ft-bifrost-bridge/onchain`): config
field 3 repurposed (renamed), a new trie validator, a rewritten `peg-out.ak`. Scalus (`binocular`):
the TM Confirm branch gains the marker-pair walk + trie-root fold; CLI gains the
trie spend and bootstrap. Rust (`heimdall`): the TM builder emits marker pairs
and the peg-out selection switches from outpoint-pin discipline to the
freshness filter + trie dedup.

**Tech Stack:** Aiken v1.1.x (`aiken-lang/merkle-patricia-forestry`), Scalus
1.0.0 (`MerklePatriciaForestry` on-chain), Rust (bitcoin crate), sbt, cargo.

## Global Constraints

- NEVER commit inside `ft-bifrost-bridge/offchain/*` submodule checkouts — commit
  in `/Users/nau/projects/lantr/binocular` and `/Users/nau/projects/lantr/heimdall`,
  then bump the submodule refs in the main repo.
- No Claude co-author trailers in commit messages. No em dashes in prose.
- binocular test runs: `sbt blueprintPin`, then
  `rm -rf target/**/resource_managed` if packageBin reports duplicate blueprint
  zip entries, then `SCALUS_SKIP_BLUEPRINT=1 sbt "testOnly *"`.
- heimdall test runs: `nix develop --command env RUSTC_BOOTSTRAP=1 cargo test`.
- Aiken runs from `onchain/`: `aiken check && aiken build`.
- Constants fixed by the spec: trie NFT asset name `"FPO"`; marker script prefix
  `6a23504f52` (`OP_RETURN OP_PUSHBYTES_35 "POR"`); marker script length 37;
  POR id = `sha2_256(serialise_data(OutputReference))`; trie value =
  `dest_spk ++ amount_le8`; cancel timeout 30 days (ms); heimdall freshness
  margin default 7 days.
- Config slot reuse: NO new config field. Field 3 (type PolicyId, position
  frozen) is renamed to `fulfilled_peg_outs_merkle_tree_policy_id`; the
  migration Update swaps its VALUE to the new trie policy. The binocular
  mirror stays 17 fields (decodes pre- and post-migration configs). The new
  TM script goes live only after that Update.

---

### Task 1: Aiken — repurpose config field 3 + FPO constant

**Files:**
- Modify: `onchain/lib/bifrost/constants.ak`
- Modify: `onchain/lib/bifrost/types/config.ak`
- Modify: every `ConfigDatum { ... }` literal that names field 3
  (`grep -rn "completed_peg_outs_merkle_tree_policy_id" onchain/` — at least
  the `types/config.ak` pin test, `onchain/validators/bitcoin/config.ak:162`,
  `onchain/validators/bitcoin/bridged-token.ak:85`)

**Interfaces:**
- Produces: `constants.fulfilled_peg_outs_root_asset_name = "FPO"`;
  `config.get_fulfilled_peg_outs_merkle_tree_policy_id(fields) -> PolicyId`
  reading index 3; `ConfigDatum.fulfilled_peg_outs_merkle_tree_policy_id`
  (renamed field 3 — position and type unchanged).

- [ ] **Step 1: Add the constant** (`completed_peg_outs_root_asset_name` is
  deleted in Task 3 together with the CPO validator)

```aiken
pub const fulfilled_peg_outs_root_asset_name = "FPO"
```

- [ ] **Step 2: Rename ConfigDatum field 3** from
  `completed_peg_outs_merkle_tree_policy_id` to
  `fulfilled_peg_outs_merkle_tree_policy_id` with a comment:

```aiken
  //Policy id (= script hash) of the fulfilled-peg-outs trie NFT: the MPF of
  //every peg-out ever paid by a confirmed TM, keyed by POR id. Read by the
  //Scalus TM validator (confirm) and peg-out.ak (Complete/Cancel).
  //REPURPOSED SLOT: held the retired completed-peg-outs trie policy until the
  //2026-07 migration swapped the value (the old peg-out.ak was its only
  //on-chain reader; the old CPO UTxO is abandoned in place).
  fulfilled_peg_outs_merkle_tree_policy_id: PolicyId,
```

- [ ] **Step 3: Rename the index-3 getter** to
  `get_fulfilled_peg_outs_merkle_tree_policy_id` (body unchanged:
  `safe_list_at(config_fields, 3)`); update the pin-test assertion to the new
  names. Old `peg-out.ak` still calls the old getter name — it is rewritten in
  Task 3; until then the build is red, so Tasks 1–3 land as ONE commit series
  with `aiken check` green only at Task 3's end (or do the mechanical rename
  in `peg-out.ak` here and let Task 3 delete it).

- [ ] **Step 4: Fix every ConfigDatum literal** the compiler now rejects
  (field rename only — values unchanged).

- [ ] **Step 5: Verify**

Run: `cd onchain && aiken check`
Expected: 0 failures once the getter rename is threaded (see Step 3 note).

- [ ] **Step 6: Commit** — `feat(onchain): repurpose config field 3 for the fulfilled-peg-outs trie + FPO constant`

---

### Task 2: Aiken — `fulfilled-peg-outs-merkle-tree.ak`

**Files:**
- Create: `onchain/validators/bitcoin/fulfilled-peg-outs-merkle-tree.ak`

**Interfaces:**
- Consumes: `constants.fulfilled_peg_outs_root_asset_name`.
- Produces: validator `fulfilled_peg_outs_merkle_tree_validator(tm_nft_policy_id:
  ByteArray, one_shot_input_ref: OutputReference)` with `mint` (bootstrap) and
  `spend` (gated on a TM Unconfirmed→Confirmed transition). Datum
  `FulfilledPegOutsMerkleTreeDatum { root: ByteArray }`.

- [ ] **Step 1: Write the validator** (bootstrap mint copied from
  `completed-peg-outs-merkle-tree.ak`; spend replaced by the TM-transition gate)

```aiken
use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use bifrost/constants
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}

pub type FulfilledPegOutsMerkleTreeDatum {
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

fn carries_tm_nft(value: assets.Value, tm_nft_policy_id: ByteArray) -> Bool {
  quantity_of(value, tm_nft_policy_id, constants.btc_asset_name) == 1
}

validator fulfilled_peg_outs_merkle_tree_validator(
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
      minted_asset_name == constants.fulfilled_peg_outs_root_asset_name,
      trie_output.datum == InlineDatum(
        FulfilledPegOutsMerkleTreeDatum {
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
  //validator in the same transaction (the mirror of how the completed tries
  //delegate to peg_out.ak).
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
```

- [ ] **Step 2: Write tests in the same file** — fixture `Transaction`s built
  with `cardano/transaction` mocks (follow the existing test style in
  `onchain/validators/bitcoin/config.ak`): (a) spend passes with TM tag-0 input
  + tag-1 output; (b) fails with no TM input; (c) fails when the TM input datum
  is tag 1 (GC spend, not Confirm); (d) fails when the output tag is 0;
  (e) fails when the "TM" input carries a different policy; (f) bootstrap mint
  happy path; (g) bootstrap fails on wrong asset name / non-empty root /
  missing one-shot input.

- [ ] **Step 3: Verify** — `aiken check` (all new tests pass), then **Commit**
  — `feat(onchain): fulfilled-peg-outs trie validator (TM-confirm-gated)`

---

### Task 3: Aiken — `peg-out.ak` + `types/peg-out.ak` rewrite

**Files:**
- Rewrite: `onchain/lib/bifrost/types/peg-out.ak`
- Rewrite: `onchain/validators/bitcoin/peg-out.ak`
- Delete: `onchain/validators/bitcoin/completed-peg-outs-merkle-tree.ak`
  (nothing can ever spend the deployed CPO UTxO after the field-5 swap — its
  compiled redeemer decode only matches the OLD shape — and fresh deploys do
  not bootstrap it; dead source goes, per the 7b7a7ee precedent)
- Modify: `onchain/lib/bifrost/constants.ak` (drop
  `completed_peg_outs_root_asset_name`)

**Interfaces:**
- Consumes: `config.get_fulfilled_peg_outs_merkle_tree_policy_id` (Task 1),
  `constants.fulfilled_peg_outs_root_asset_name`, `utils.hash_output_ref`,
  `utils.get_mpf_from_output`, `bifrost/authorizer`.
- Produces: `PegOutDatum { owner_auth, source_chain_destination_address,
  per_pegout_fee, created }`; `PegOutWithdrawRedeemer { config_ref_input_index,
  fulfilled_trie_ref_input_index, action_type }`;
  `PegOutActionType = CompletePegOut { membership_proof } | Cancel { exclusion_proof }`.

- [ ] **Step 1: New `types/peg-out.ak`**

```aiken
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
  //Prove the fulfilled-peg-outs trie maps this POR id to
  //dest_spk ++ amount_le8 and burn the locked fBTC.
  CompletePegOut { membership_proof: mpf.Proof }
  //After the timeout, prove this POR id is NOT in the trie and reclaim.
  Cancel { exclusion_proof: mpf.Proof }
}

pub type PegOutWithdrawRedeemer {
  config_ref_input_index: Int,
  fulfilled_trie_ref_input_index: Int,
  action_type: PegOutActionType,
}
```

- [ ] **Step 2: New `peg-out.ak`** (oracle parameter kept for hash-churn-free
  future use is NOT needed — drop it; parameters become just the config NFT)

```aiken
use aiken/builtin
use aiken/collection/list
use aiken/interval
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
use bifrost/authorizer.{authorize_action, create_auth}
use bifrost/constants
use bifrost/types/config
use bifrost/types/peg_out.{
  Cancel, CompletePegOut, PegOutDatum, PegOutWithdrawRedeemer,
}
use bifrost/utils
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, OutputReference, Transaction}

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
    let config_fields =
      utils.get_config_as_data_list(
        utils.safe_list_at(
          self.reference_inputs,
          redeemer.config_ref_input_index,
        ),
        config_nft_policy_id,
        config_nft_asset_name,
      )
    let bridged_token_policy_id =
      config.get_bridged_token_policy_id(config_fields)
    let bridged_token_asset_name =
      config.get_bridged_token_asset_name(config_fields)
    let fulfilled_trie_policy_id =
      config.get_fulfilled_peg_outs_merkle_tree_policy_id(config_fields)

    //The fulfilled-peg-outs trie is a REFERENCE input (never spent here):
    //authenticated by its NFT, it pins the current root — a stale root is
    //impossible (a spent trie outpoint cannot be referenced).
    let trie_ref_input =
      utils.safe_list_at(
        self.reference_inputs,
        redeemer.fulfilled_trie_ref_input_index,
      )
    expect
      quantity_of(
        trie_ref_input.output.value,
        fulfilled_trie_policy_id,
        constants.fulfilled_peg_outs_root_asset_name,
      ) == 1
    let fulfilled_trie = utils.get_mpf_from_output(trie_ref_input.output)

    expect [peg_out_input] =
      list.filter(
        self.inputs,
        fn(input) { input.output.address.payment_credential == credential },
      )
    expect InlineDatum(input_datum) = peg_out_input.output.datum
    expect datum: PegOutDatum = input_datum

    //POR id: hash of this request's own outpoint — globally unique, needs no
    //datum field, and is exactly what the TM's "POR" marker committed.
    let por_id = utils.hash_output_ref(peg_out_input.output_reference)

    let bridged_tokens_locked =
      quantity_of(
        peg_out_input.output.value,
        bridged_token_policy_id,
        bridged_token_asset_name,
      )

    let user_authorized =
      authorize_action(
        create_auth(
          datum.owner_auth,
          self.inputs,
          self.reference_inputs,
          self.withdrawals,
          self.extra_signatories,
          self.mint,
        ),
      )

    when redeemer.action_type is {
      CompletePegOut { membership_proof } -> {
        //The confirmed TM paid dest exactly (locked − pinned fee) satoshi:
        //the trie maps this POR id to dest_spk ++ amount_le8 (8-byte LE).
        let net_amount = bridged_tokens_locked - datum.per_pegout_fee
        let expected_value =
          bytearray.concat(
            datum.source_chain_destination_address,
            builtin.integer_to_bytearray(False, 8, net_amount),
          )
        let fulfilled_proven =
          mpf.has(fulfilled_trie, por_id, expected_value, membership_proof)
        //All locked fBTC burnt — completion consumes the request entirely.
        let all_bridged_tokens_burnt =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == -bridged_tokens_locked
        and {
          user_authorized,
          fulfilled_proven,
          all_bridged_tokens_burnt,
        }
      }
      Cancel { exclusion_proof } -> {
        //Refund path: after the timeout, an id absent from the trie can never
        //be paid (the SPO freshness margin stops fulfillment long before the
        //deadline), so the fBTC unlocks back to the owner.
        let timeout_elapsed =
          interval.is_entirely_after(
            self.validity_range,
            datum.created + peg_out_cancel_timeout_ms,
          )
        let not_fulfilled =
          mpf.miss(fulfilled_trie, por_id, exclusion_proof)
        //A cancel must never mint or burn the bridged token: this keeps
        //bridged_token's presence-only delegation sound.
        let no_bridged_token_mint =
          quantity_of(self.mint, bridged_token_policy_id, bridged_token_asset_name) == 0
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
    expect Some(own_input) =
      list.find(self.inputs, fn(input) { input.output_reference == own_ref })
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
```

- [ ] **Step 3: Delete `completed-peg-outs-merkle-tree.ak`** and the
  `completed_peg_outs_root_asset_name` constant; `grep -rn "completed_peg_outs"
  onchain/` afterwards — remaining hits must only be the repurposed-slot
  comment in `types/config.ak`.

- [ ] **Step 4: Tests** (same file, aiken test blocks with an off-chain-built
  MPF fixture — build a small trie with `mpf.from_root` + known
  insert/exclusion proofs, mirroring `peg-in.ak`'s MPF test style):
  Complete: happy path; wrong value (amount off by one — fee arithmetic);
  wrong id; partial burn fails; not authorized fails.
  Cancel: happy path after timeout; fails inside timeout (boundary: validity
  lower bound == created + timeout must FAIL, entirely-after semantics);
  fails with membership id; fails when minting fBTC.
  Shared: missing trie NFT on the reference input fails.

- [ ] **Step 5: Verify + build** — `aiken check && aiken build` (regenerates
  `plutus.json` with the new peg_out + trie validators).

- [ ] **Step 6: Commit** — `feat(onchain): peg-out Complete/Cancel via the fulfilled-peg-outs trie`

---

### Task 4: binocular — TM Confirm marker walk + trie fold

**Files:**
- Modify: `src/main/scala/binocular/watchtower/TreasuryMovementValidator.scala`
- Modify: `src/main/scala/binocular/watchtower/ConfigTypes.scala`
- Test: `src/test/scala/binocular/TreasuryMovementValidatorTest.scala`

**Interfaces:**
- Consumes: `MerklePatriciaForestry` (`verifyMembership`, `insert`), Task 1's
  repurposed config field 3, `"FPO"` asset name.
- Produces: `enum FulfilledStep { Insert(proof); AlreadyPresent(proof) }`;
  `TmConfirmRedeemer(txIndex, txMerkleProof, blockMpfProof, blockHeader,
  fulfilledSteps: ScalusList[FulfilledStep])`; case class
  `FulfilledTrieDatum(root: ByteString)`; confirm-branch marker constants.

- [ ] **Step 1: ConfigTypes — rename the mirror field**
`completedPegOutsMerkleTreePolicyId` → `fulfilledPegOutsMerkleTreePolicyId`
(field 3; positional, so the rename is free). Scaladoc note: repurposed slot —
value swapped by the 2026-07 migration Update; the mirror stays 17 fields and
decodes pre- and post-migration configs alike.

- [ ] **Step 2: Redeemer + datum types**

```scala
/** One per (payment, marker) pair of the confirmed TM, in output order. */
enum FulfilledStep derives FromData, ToData {
    /** Normal: insert (por_id -> dest_spk ++ amount_le8) into the trie. */
    case Insert(proof: ScalusList[ProofStep])
    /** Tolerance: the key is already present WITH THE SAME VALUE (an SPO
      * double-fulfillment bug). Verifies membership and leaves the root
      * unchanged — a failing insert here would stall the TM chain forever,
      * stranding every peg-in the TM swept.
      */
    case AlreadyPresent(proof: ScalusList[ProofStep])
}
@Compile object FulfilledStep

case class FulfilledTrieDatum(root: ByteString) derives FromData, ToData
@Compile object FulfilledTrieDatum
```
Extend `TmConfirmRedeemer` with `fulfilledSteps: ScalusList[FulfilledStep]`.

- [ ] **Step 3: Confirm-branch additions** (in the `Unconfirmed` case, after
  the `exp === contOut.datum` check). Marker prefix constant:
  `val PorMarkerPrefix = hex"6a23504f52"` (OP_RETURN, PUSHBYTES_35, "POR").

```scala
// Fulfilled-peg-outs trie update. Outputs after the treasury change come in
// (payment, marker) pairs: the marker scriptPubKey is
// OP_RETURN OP_PUSHBYTES_35 ("POR" ++ por_id) — 37 bytes. Walk the pairs,
// fold the trie root, and require the continuing trie output to carry the
// folded root. The trie UTxO must be SPENT here (its own Aiken validator
// gates that spend on this very transition).
val cfgOut = tx.referenceInputs
    .find(_.resolved.value.quantityOf(configNftPolicy, configNftName) == BigInt(1))
    .getOrFail("TM confirm: no config reference input")
    .resolved
val triePolicy = cfgOut.datum.of[ConfigDatum].fulfilledPegOutsMerkleTreePolicyId // field 3 (repurposed)
val fpoName = ByteString.fromString("FPO")
val trieIn = tx.inputs
    .find(_.resolved.value.quantityOf(triePolicy, fpoName) == BigInt(1))
    .getOrFail("TM confirm: fulfilled-trie UTxO not spent")
    .resolved
val trieOut = tx.outputs
    .find(out => out.value.quantityOf(triePolicy, fpoName) == BigInt(1))
    .getOrFail("TM confirm: no continuing fulfilled-trie output")
require(trieOut.address === trieIn.address, "TM confirm: trie address changed")

def isMarker(spk: ByteString): Boolean =
    spk.size == BigInt(37) && spk.slice(0, 5) == PorMarkerPrefix
def markerId(spk: ByteString): ByteString = spk.slice(5, 32)

// fulfilled = allOutputs(signedBtcTx); head = treasury change (never a marker).
def fold(
    root: MPF,
    outs: ScalusList[PegOutEntry],
    steps: ScalusList[FulfilledStep]
): MPF = outs match
    case ScalusList.Nil => steps match
        case ScalusList.Nil => root
        case _              => fail("TM confirm: more steps than marker pairs")
    case ScalusList.Cons(payment, rest1) =>
        require(!isMarker(payment.scriptPubKey), "TM confirm: marker without payment")
        rest1 match
            case ScalusList.Cons(marker, rest2) =>
                require(isMarker(marker.scriptPubKey), "TM confirm: missing POR marker")
                val key = markerId(marker.scriptPubKey)
                val value = payment.scriptPubKey ++
                    integerToByteString(false, 8, payment.amount)
                steps match
                    case ScalusList.Cons(step, moreSteps) =>
                        val next = step match
                            case FulfilledStep.Insert(proof) =>
                                root.insert(key, value, proof)
                            case FulfilledStep.AlreadyPresent(proof) =>
                                root.verifyMembership(key, value, proof)
                                root
                        fold(next, rest2, moreSteps)
                    case ScalusList.Nil => fail("TM confirm: missing trie step")
            case ScalusList.Nil => fail("TM confirm: odd output count after change")

val startRoot = MPF(trieIn.datum.of[FulfilledTrieDatum].root)
val endRoot = fold(startRoot, fulfilled.tail, proof.fulfilledSteps)
require(
  trieOut.datum.of[FulfilledTrieDatum].root == endRoot.root,
  "TM confirm: trie root does not match the folded inserts"
)
```
(Adjust `MPF` construction/`root` accessor and `integerToByteString` naming to
the actual Scalus 1.0.0 API — the oracle's `BitcoinValidator` insert fold is
the reference. `.tail` of `fulfilled` skips the treasury change output; a
zero-peg-out TM has `fulfilled.tail == Nil` and `fulfilledSteps == Nil`.)

- [ ] **Step 4: Tests** — extend the confirm fixtures with a trie UTxO
  (in + out), a config reference input (17-field datum), and TM txs built with
  marker pairs. Cases: happy 1-peg-out; happy 3-peg-out; zero-peg-out (empty
  steps, root unchanged); `AlreadyPresent` accepted with same value, rejected
  with different value; wrong final root; missing trie input; forged trie NFT
  policy; odd output count; marker with wrong prefix (`"BFR"` payload);
  payment position holding a marker; steps/pairs count mismatch. Confirm the
  existing suite still passes (old fixtures need the trie + config wiring and
  empty-marker TMs).

- [ ] **Step 5: Verify** — `sbt blueprintPin` then
  `SCALUS_SKIP_BLUEPRINT=1 sbt "testOnly *TreasuryMovement*"`, then the full
  `"testOnly *"`.

- [ ] **Step 6: Commit** (in `/Users/nau/projects/lantr/binocular`) —
  `feat(tm): fulfilled-peg-outs trie fold at Confirm (POR marker pairs)`

---

### Task 5: binocular — CLI: confirm builds the trie spend; deploy + config

**Files:**
- Modify: `src/main/scala/binocular/cli/commands/ConfirmTmtxCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/DeployBridgeCommand.scala`
- Modify: `src/main/scala/binocular/cli/commands/UpdateConfigCommand.scala`
- Modify: `src/main/scala/binocular/watchtower/BridgeConfig.scala` (trie policy
  / bootstrap settings if the deploy flow needs them)

**Interfaces:**
- Consumes: Task 4 types; the Aiken blueprint of
  `fulfilled_peg_outs_merkle_tree_validator` (from `onchain/plutus.json`,
  applied params: new TM hash + one-shot ref).
- Produces: confirm txs that spend the trie UTxO with correct `FulfilledStep`
  proofs; `UpdateConfigCommand` swaps fields 3 and 5.

- [ ] **Step 1: ConfirmTmtxCommand** — locate the trie UTxO by NFT; rebuild the
  off-chain MPF (reconstruct by replaying all Confirmed records' pairs, or
  incrementally from the previous datum + this TM's pairs — use the same
  off-chain `MerklePatriciaForestry` the oracle CLI uses for block-root
  proofs); generate one `Insert` proof per pair (fall back to
  `AlreadyPresent` when the key is already present with the same value);
  extend the redeemer; add the trie input + continuing output (same address,
  NFT + min-ADA, new root datum).
- [ ] **Step 2: DeployBridgeCommand** — one-shot bootstrap of the FPO trie
  UTxO, replacing the CPO bootstrap outright (reuse its code path); genesis
  config field 3 = the new trie policy. Fresh deploys create no CPO UTxO.
- [ ] **Step 3: UpdateConfigCommand** — extend `rewriteFields` with
  `--fulfilled-trie-policy <hash>` (replace index 3) and
  `--peg-out-withdraw-hash <hash>` (replace index 5), keeping raw-field-list
  operation (works pre-migration).
- [ ] **Step 4: Verify** — `blueprintPin` + full `SCALUS_SKIP_BLUEPRINT=1 sbt
  "testOnly *"`; `Commit` —
  `feat(cli): confirm-tmtx trie spend + config field 3 migration path`

---

### Task 6: heimdall — marker pairs, freshness filter, trie dedup

**Files:**
- Modify: `src/bitcoin/tm_builder.rs`
- Modify: `src/cardano/blockfrost_chain.rs` (POR scanner + trie root query)
- Modify: `src/cardano/treasury_datum.rs` / datum parsing (4-field PegOutDatum)
- Modify: `src/config.rs` (freshness margin setting, default 7 days)
- Test: module tests alongside each

**Interfaces:**
- Consumes: 4-field `PegOutDatum {owner_auth, dest_spk, per_pegout_fee,
  created}`; the fulfilled-trie UTxO datum root.
- Produces: `PegOutRequest { script_pubkey: ScriptBuf, amount: Amount,
  per_pegout_fee: Amount, por_id: [u8; 32] }`; TM txs with (payment, marker)
  pairs; selection filter.

- [ ] **Step 1: tm_builder** — extend `PegOutRequest` as above (per-request fee
  replaces the global `FeeParams.per_pegout_fee` in the dust/net computation);
  after the existing sort by payment `script_pubkey`, emit per peg-out the
  payment output followed by
  `TxOut { value: Amount::ZERO, script_pubkey: marker_script(por_id) }` where

```rust
/// OP_RETURN OP_PUSHBYTES_35 "POR" ++ por_id — the FROST-signed commitment
/// binding this payment output to exactly one PegOutRequest UTxO. "POR", not
/// a "BFR"-prefixed tag: watchtowers detect peg-in deposits by scanning for
/// "BFR" OP_RETURN payloads and a TM pays the treasury address.
fn marker_script(por_id: &[u8; 32]) -> ScriptBuf {
    let mut payload = Vec::with_capacity(35);
    payload.extend_from_slice(b"POR");
    payload.extend_from_slice(por_id);
    ScriptBuf::new_op_return(PushBytesBuf::try_from(payload).expect("35 <= 75"))
}
```
  vsize: `num_outputs = 1 + 2 * pegouts.len()`, per-marker output size
  `8 + 1 + 37 = 46` bytes (update `estimate_vsize` with a per-marker term).
  Remove the outpoint-pin skip logic (`skip peg-outs pinned to another
  treasury outpoint`); keep dust/standardness skips.
- [ ] **Step 2: Selection filter + dedup** — in the peg-out scan: parse the
  4-field datum; compute `por_id = sha256(plutus_data_cbor(OutputReference))`
  (golden-test against Aiken's `hash_output_ref`); skip when
  `created > now` or `created + CANCEL_TIMEOUT_MS - now < margin_ms`
  (config `pegout_freshness_margin_days`, default 7); skip ids already in the
  fulfilled trie (replaces `never re-pay a peg-out an earlier TM already
  paid`, which walked Confirmed records — the trie is now the canonical
  paid-set; keep the Confirmed-record walk as the trie mirror source).
- [ ] **Step 3: Tests** — builder determinism with pairs (byte-identical across
  input orders), marker script golden bytes, vsize, freshness boundaries
  (margin edge exactly), por_id golden vector shared with Task 3's Aiken test.
- [ ] **Step 4: Verify** — `nix develop --command env RUSTC_BOOTSTRAP=1 cargo
  test`; `Commit` (in `/Users/nau/projects/lantr/heimdall`) —
  `feat(pegout): POR marker pairs + freshness/trie-dedup selection`

---

### Task 7: Documentation + runbook

**Files:**
- Modify: `documentation/technical_documentation.md`
- Modify: `documentation/tm-chain-migration-runbook.md`
- Modify: `docs/superpowers/specs/2026-07-22-peg-out-fulfilled-trie-design.md`
  (Status: Approved → Implemented refs)

- [ ] **Step 1:** §Complete peg-out — withdraw [CPO-1], [CPO-2], [CPO-4]–[CPO-8]
  (strike-through + "withdrawn (fulfilled-trie design, 2026-07-22)"), keep
  [CPO-3]/[CPO-9]/[CPO-10], add [CPO-11] (trie reference input authenticated by
  NFT from Config #17), [CPO-12] (membership of `por_id` with value
  `dest_spk ++ amount_le8`, net of the pinned fee).
- [ ] **Step 2:** §Cancel PegOut request — withdraw [CXL-1]–[CXL-4]; keep
  [CXL-5]/[CXL-6]; add [CXL-7] (validity entirely after `created + 30 d`),
  [CXL-8] (non-membership of `por_id`), [CXL-9] (no bridged-token mint/burn).
- [ ] **Step 3:** §Create PegOut request — new datum table (drop
  `source_chain_treasury_utxo_id` + both "permanently unrecoverable" warnings
  tied to it; add `created` + the freshness-margin note), client-side checks.
- [ ] **Step 4:** §Confirm TM tx — add [CTM-*] checks for the trie spend +
  marker-pair fold; fix the "peg-out completion … verifies the raw TM directly
  against Binocular" sentence; §Treasury Movement Transaction gains the
  marker-pair output layout; stale Config #15 implementation-status note
  (N7 fields exist) corrected in passing.
- [ ] **Step 5:** Config table + parameter registry: field 3 re-documented
  (repurposed slot, swap in the migration); fields 7/8 marked vestigial. UTxO
  map: fulfilled-trie singleton row replaces the completed-peg-outs row (noted
  abandoned + permanently unspendable post-swap).
- [ ] **Step 6:** Runbook: trie bootstrap step, field-3 + field-5 swaps in
  the Update, new reward-account registration for peg_out.
- [ ] **Step 7: Commit** —
  `docs(spec): peg-out termination via the fulfilled-peg-outs trie`

---

### Task 8: Submodule bumps + end-to-end verification

- [ ] **Step 1:** Push binocular and heimdall; in `ft-bifrost-bridge` bump both
  submodule refs (`git -C offchain/bitcoin-watchtower/binocular fetch origin &&
  git -C ... checkout <sha>`, same for heimdall), commit
  `chore: bump submodules - peg-out fulfilled-trie implementation`.
- [ ] **Step 2:** Full verification sweep: `aiken check` (onchain),
  `SCALUS_SKIP_BLUEPRINT=1 sbt "testOnly *"` (binocular), `cargo test`
  (heimdall). All green before push.
- [ ] **Step 3:** Push `ft-bifrost-bridge` main.
