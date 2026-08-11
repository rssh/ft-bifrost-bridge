# Treasury Key Lifecycle: a Next-Epoch Slot and One Federation Fallback

Date: 2026-08-07. Status: **POSTPONED, not approved, do not implement.**

> **Why postponed, and what is wrong with it.** A review found the central
> mechanism broken: [UY-2] writes only `next_spos_frost_key` while [UY-3]
> verifies under `current_spos_frost_key`, and nothing ever promotes one to the
> other. Since the bootstrap seeds `current` with `y_federation`, rotation
> authority would freeze at the federation key forever and the roster path would
> never exist. Three further defects follow from the same area: `last_rotation`
> and the effective epoch sit outside the signed message, so a permissionless
> submitter can inflate the timeout and disable the federation fallback; no
> minimum lead time is required, so the derivation flip can be immediate; and the
> trust bound in §Trust model change is detection without remedy, because in the
> case the branch exists for nobody can act on the detection.
>
> The fix is known and concrete: verify under the epoch-effective key, promote
> lazily at the next rotation, commit the effective time in the signed message,
> bound the validity width, and require a minimum lead. It touches nearly every
> check here, so the document is parked rather than patched.
>
> `2026-08-06-bridge-state-singleton-design.md` therefore stands alone. It keeps
> `last_federation_sweep_txid`, [CTM-22], [CTM-31] and [UY-7] to [UY-10], which
> this design would have deleted. Nothing in it depends on this document.

This design replaces the treasury group key's rotation and recovery machinery.
It makes three changes:

1. `TreasuryDatum` gains a next-epoch key slot, so the depositor-facing address
   flips at an announced moment instead of at a datum write.
2. Update-Y gains a federation branch, authorized by a timeout rather than by
   evidence of a Bitcoin sweep.
3. The `FederationReset` branch is withdrawn. The federation branch subsumes it.

It assumes the fresh deployment of
`2026-08-06-bridge-state-singleton-design.md` (rev 5.4). Were it approved it
would remove work from that revision: `last_federation_sweep_txid`, [CTM-22],
[CTM-31] and [UY-7] to [UY-10] would all disappear. While this design is
postponed they stay.

> **Implementation status.** Nothing here is implemented. `treasury.ak` today has
> `UpdateY` and `FederationReset` branches matching the current specification.
> Separately, no code path produces a FROST threshold signature over the Update-Y
> message: the CLI takes a single key or a supplied signature, so the roster path
> below cannot be executed yet by any component.

## Definitions

| Term | Meaning |
|---|---|
| **outgoing roster** | The roster whose key is `current_spos_frost_key`. It signs the rotation away from itself. |
| **incoming roster** | The roster that ran DKG for the next epoch. Its key becomes `next_spos_frost_key`. |
| **handoff TM** | The Treasury Movement that moves the treasury to the incoming roster's address. |
| **federation** | The x-only key `y_federation`, per the federation charter. |

## Problem

**Defect 1: the depositor-facing address flips at a datum write.** Update-Y lands
by `update_y_deadline`, about E+3h, and from that instant depositors derive from
the new key. The outgoing roster keeps signing batches until the handoff TM. A
deposit sent to the OLD address shortly before that write is rescued only if a
batch happens to sweep it first, and no rule obliges the outgoing roster to
sweep old-address deposits before it stops signing. The specification's answer
today is that the depositor waits out the roughly 30-day refund.

The asymmetry is visible in the specification itself: a federation-key rotation
MUST sweep or refund in-flight peg-ins first, and no equivalent rule exists for
the roster key.

**Defect 2: the handoff moment is specified twice, incompatibly.** One passage
says the final TM of the epoch performs the handoff. Another says it is
whichever batch first runs after Update-Y lands. With `update_y_deadline` at
E+3h and `tm_batch_interval` at 6h the second rule makes the FIRST batch the
handoff, so the window to drain old-address deposits is about three hours rather
than an epoch.

**Defect 3: a live incoming roster can be dumped into federation mode.** If DKG
succeeds but the OUTGOING roster dies before signing the rotation, nobody can
install the new key. [UY-6] restricts the federation to setting `y_federation`,
so the only available recovery discards a perfectly good roster key.

**Defect 4: the recovery machinery is disproportionate.** Proving the roster dead
costs a witness-shape computation at every TM Confirm, a datum field carried
forever, and a freshness anchor, all for an event that happens at most once per
dead roster.

## Design

### Datum

```aiken
pub type TreasuryDatum {
  bifrost_identity_root: ByteArray,
  //Whose signature authorizes the next rotation. Deposits derive from this
  //until next_effective_epoch arrives.
  current_spos_frost_key: ByteArray,
  //The incoming roster's key. Empty when no rotation is pending.
  next_spos_frost_key: ByteArray,
  //The epoch at which next_spos_frost_key becomes the derivation key.
  next_effective_epoch: Int,
  //POSIX ms of the last successful rotation. Anchors the federation timeout.
  last_rotation: Int,
  y_federation: ByteArray,
  federation_csv_blocks: Int,
  federation_rotation_timeout: Int,
}
```

`last_reset_tm_txid` is gone with the reset branch.

> **Why promotion needs no transaction.** No validator reads
> `current_spos_frost_key` except Update-Y itself, to decide whose signature is
> required. Address derivation and FROST signing are entirely off-chain. So the
> datum can carry both keys and an effective epoch, and every off-chain reader
> picks by epoch. Promoting `next` into `current` at a boundary would need
> somebody to spend the treasury state UTxO for no on-chain benefit.

### Update-Y, two authorizations

```
Roster path      BIP340 under current_spos_frost_key       any time
Federation path  BIP340 under y_federation                 after the timeout
```

Both write `next_spos_frost_key` and `next_effective_epoch`, never
`current_spos_frost_key`. Both set `last_rotation`.

### The four cases

| DKG | Outgoing roster | Who installs, and what |
|---|---|---|
| succeeded | alive | the roster, `next := Y_incoming` |
| succeeded | dead | the federation after the timeout, `next := Y_incoming` |
| failed | alive | the roster, `next := current`. See [KEY-6] |
| failed | dead | the federation after the timeout, `next := y_federation` |

Row two is why the federation branch may name an arbitrary key. Row four is what
`FederationReset` used to do.

> **Why `y_federation` and not a zero sentinel.** An earlier sketch set the key to
> zero on DKG failure. A zero key makes the treasury unspendable and forces every
> address-derivation site to special-case a magic value. Setting `y_federation`
> puts the bridge in Phase 1, a state it already knows how to occupy, and the
> handback is then an ordinary roster rotation.

## Checks

### Update-Y, roster path

- [UY-1] SURVIVES UNCHANGED. The continuing output is at `treasury.ak` and
  carries the Treasury state NFT.
- [UY-2] REVISED. The datum transition MUST change only
  `next_spos_frost_key`, `next_effective_epoch` and `last_rotation`.
- [UY-3] SURVIVES UNCHANGED. The signature verifies under the spent datum's
  `current_spos_frost_key`.
- [UY-4] REVISED. The 32-byte check now applies to `next_spos_frost_key`.
- [UY-11] `treasury.ak` MUST verify `next_effective_epoch` is greater than the
  epoch the signed message names.
- [UY-15] `treasury.ak` MUST permit `next_spos_frost_key` to equal
  `current_spos_frost_key`, which is the [KEY-6] liveness rotation.
- [UY-12] `treasury.ak` MUST verify `last_rotation` equals the transaction's
  validity upper bound.

### Update-Y, federation path

- [UY-5] REVISED. `treasury.ak` MUST verify the rotation is authorized by a
  BIP340 signature under `y_federation`.
- [UY-6] WITHDRAWN. The federation MAY now name any key. See §Trust model
  change.
- [UY-7] WITHDRAWN. No sweep evidence is required.
- [UY-8] WITHDRAWN. No freshness anchor is required.
- [UY-13] `treasury.ak` MUST verify the validity range lies entirely after
  `last_rotation + federation_rotation_timeout`.
- [UY-11] and [UY-12] apply to this path too.

### FederationReset

- [UY-14] WITHDRAWN as a transaction. `treasury.ak` MUST NOT carry a
  `FederationReset` spend branch. The federation path above covers every case it
  covered.

> **Why replay protection is free.** The signed message already commits to the
> spent treasury outpoint, and `last_rotation` advances on every rotation. A
> stale federation signature therefore dies the moment any rotation succeeds,
> which is what [UY-8] was buying with a txid comparison.

### Off-chain obligations

- [KEY-1] The outgoing roster MUST sweep or refund every deposit at an
  old-address before `next_effective_epoch`.
- [KEY-2] Depositors MUST derive from `current_spos_frost_key` until
  `next_effective_epoch`, and from `next_spos_frost_key` from that epoch on.
- [KEY-3] The federation MUST post the federation path once the timeout elapses
  and DKG has succeeded, naming the incoming roster's key.
- [KEY-4] The federation MUST post `y_federation` as the key when DKG has
  failed and the outgoing roster cannot sign.
- [KEY-5] heimdall MUST read `federation_rotation_timeout` and the effective
  epoch from `treasury.ak`, not from local configuration.
- [KEY-6] When DKG fails and the outgoing roster can still sign, that roster MUST
  post an Update-Y setting `next_spos_frost_key` to its own current key.

> **Why [KEY-6] is mandatory and not a courtesy.** `last_rotation` advances only
> when a rotation succeeds, so without it a live roster that merely fails DKG
> looks identical on-chain to a dead one. Two failed epochs would age the anchor
> past `federation_rotation_timeout` and let the federation demote a roster that
> is signing batches perfectly well. That is the theft case the withdrawn [UY-7]
> existed to prevent, reintroduced through the back door.
>
> A rotation to the roster's OWN key fixes it, because the anchor should measure
> "the roster can still produce a threshold signature", not "the key changed".
> [UY-3] already requires that signature, so the no-op rotation IS the liveness
> proof. It costs one transaction per failed epoch.

> **Why [KEY-1] is the rule the specification is missing today.** It is the
> roster-key analogue of the existing sweep-or-refund rule for a federation-key
> rotation. With a next-epoch slot it finally has a deadline to attach to. It
> also resolves Defect 2: the handoff TM is whichever batch drains the old
> addresses, and it MUST land before the effective epoch.

> **How the federation learns the DKG result, and why [KEY-3] is a duty rather
> than a check.** DKG runs among the SPOs and the federation is not a
> participant, so nothing on-chain can verify that a key the federation posts is
> the one DKG produced. [KEY-3] and [KEY-4] are charter obligations, enforced by
> the same accountability that governs the federation's custody role. The
> incoming roster can detect a wrong key immediately, because it cannot sign with
> it.

## Trust model change

[UY-6] restricted the federation to setting `y_federation`. That bound a
partially compromised federation, one internal threshold, to moving custody only
to the publicly chartered identity. Withdrawing it means such a threshold can
name any key.

This is accepted deliberately, for row two of the four cases: a live incoming
roster with a valid key should not be discarded because the outgoing roster died.
The price is that the federation's key-naming power is now as broad as its
custody power already was.

Two things bound it. The timeout means the federation cannot act while any
rotation is happening. And the incoming roster detects a wrong key at once,
because it cannot produce signatures with a key it does not hold.

## What this deletes

| Removed | Was for |
|---|---|
| `last_federation_sweep_txid` in `BridgeState` | carrying sweep evidence to the reset |
| [CTM-22], [CTM-31] | writing and carrying that evidence at every Confirm |
| `isValidScriptPathWitness` at Confirm | computing it from the raw witness |
| `last_reset_tm_txid` in `TreasuryDatum` | [UY-8] freshness |
| `FederationReset` branch | subsumed by the federation path |

The Bitcoin federation CSV leaf is UNCHANGED. The federation can still sweep an
aged treasury, and that remains the fund-recovery path. Only the Cardano key
rotation stops depending on it, so the two recoveries become independent instead
of one gating the other.

## Unresolved in the source specification

These are contradictions this design touches but does not by itself fix. They
need the catalog edited.

- DKG failure is described twice and incompatibly. One passage says the old
  roster carries over with no special state. Another says the threshold mode is
  unavailable for the epoch. The first is correct and this design assumes it.
- Two passages state that no DKG result is posted on Cardano. Update-Y posts the
  group key, so both are stale.
- `update_y_deadline` is enforced nowhere: no validator reads it, heimdall has no
  such constant, and the Update-Y validity interval is unconstrained. Under this
  design the binding deadline is `next_effective_epoch`, which [UY-11] does
  constrain.

## Open items

1. **`federation_rotation_timeout` value.** It MUST exceed the epoch length with
   margin, because the roster rotates once per epoch after DKG. It belongs in
   the federation charter next to `federation_csv_blocks`.
2. **`next_effective_epoch` granularity.** Epoch is the natural unit, but the
   effective moment must be one every depositor-facing client can compute
   identically. A slot number may be safer than an epoch number.
3. **Federation-key rotation** remains specified only as a row in the
   field-permission matrix, with no transaction entry and no on-chain branch. It
   is untouched here and still needs a design.
