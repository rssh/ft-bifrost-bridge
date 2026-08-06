# Final optimizations — deferred work and open questions

**Status: not normative.** `technical_documentation.md` is the specification; this document owns
the things deliberately *not* done yet. Nothing here blocks the bridge from operating. Each entry
records what the current behaviour is, why it is acceptable for now, what the alternatives are,
and what would make it worth revisiting.

An item leaves this document in one of two ways: it is implemented, and the specification absorbs
it; or it is decided against, and the reasoning moves into the specification as a *why-not* note.

---

## 1. Reference scripts are deployed per operator, not per instance

**Current behaviour.** Heimdall deploys three CIP-33 reference scripts — `spos_registry`
(`deploy-registry-ref`), `spo_bans` (`deploy-spo-bans-ref`) and the equivocation fault verifier
(`deploy-fault-ref`) — each as output #0 at the deploying wallet's own address, reclaimable by its
creator. The consuming transaction is told where to find one out of band; `register-spo` takes a
`registry_ref` argument.

The `spos_registry` reference exists for a hard reason: the script is around 12 KB, and
`register_spo` would otherwise embed it twice, which does not fit the 16 KB transaction limit.

**Why this is redundant.** Every SPO on one bridge instance computes the *same* script hashes,
because all three are parameterized by that instance's bootstrap outpoints. A reference script is
public — any transaction may reference any reference-script UTxO regardless of who created it. So
one deployment per instance would serve every operator, and N operators each deploying their own
locks N times the ADA for no benefit. Heimdall sizes the output itself, at
`(script_size + 600) * 4310` lovelace (`register_spo.rs`), so a ~12 KB script parks about 55 ADA —
four operators lock roughly 220 ADA where one would do.

Note this redundancy exists only *within* an instance. Two bridge instances have different
bootstrap outpoints, hence different script hashes, and share nothing.

**Why it is acceptable for now.** Sharing is not free either. Because the UTxO sits at the
creator's own address and is reclaimable, an operator who relies on someone else's reference
script loses their `register-spo` path the moment that person reclaims their ADA. Per-operator
deployment costs ADA; sharing costs a liveness dependency on another operator's goodwill. At the
current scale the ADA is the cheaper problem.

**The three options, if revisited.**

1. *One shared, reclaimable reference script.* Cheapest, but couples every operator's liveness to
   whoever owns the UTxO.
2. *One shared, unspendable reference script.* Deploy to an address nobody can spend from, so the
   UTxO is permanent and the ADA is knowingly burned rather than reclaimable. This is the standard
   Cardano pattern for shared reference scripts, and it removes the liveness coupling.
3. *Per operator*, as today.

**The likely resolution: discover-or-create, in the daemon.** Today reference-script deployment is
a manual CLI step — `build_ref_script_deploy_tx` is reachable only from the three `deploy-*-ref`
commands, and `register_spo` takes the outpoint as an argument the operator supplies. Nothing
searches for an existing reference script, although Blockfrost already returns
`reference_script_hash` on every UTxO and heimdall's own `bf_http` type carries it.

Moving this into the daemon's startup would fix both halves at once, **provided it discovers before
it creates**: derive the script hash from the config, scan for a UTxO whose `reference_script_hash`
matches, use it if present, deploy only if absent. Whoever starts first pays; every later operator
reuses. One reference script per instance emerges with no coordination.

A daemon also answers the liveness objection that makes sharing unattractive today. A one-shot CLI
command cannot recover when the owner reclaims the UTxO; a daemon notices on its next pass and
redeploys. The coupling stops being fatal and becomes self-healing — which makes option 1 viable
without needing option 2's permanently burned ADA.

The failure mode to avoid is a daemon that *always* creates on first run. That produces one
reference script per operator automatically, turning a deliberate cost into an invisible one.

**What would make this worth doing.** A roster large enough that the locked ADA matters, or a
deployment where operators do not trust each other enough to depend on a reclaimable UTxO.

**A consequence for the discovery rule.** *The Config as the discovery root* requires everything an
off-chain component needs to be reachable from the config NFT policy id, and lists secrets and
machine-local settings as out of scope. Reference-script locations belong in that same out-of-scope
bucket **while option 3 stands**: a reclaimable UTxO's outpoint would go stale in the datum the
moment someone reclaimed it. Under option 2 that argument disappears — a permanent shared reference
script is exactly the kind of thing the Config *could* name.

---

## 2. Two catalog transactions have no off-chain builder

`Cancel PegOut request` (`CXL-1..9`) and `Close PegInRequest` (`CLR-1..4`) are fully specified,
with check inventories, and neither heimdall nor binocular builds them. Binocular has a
`CloseCommand`, but it operates on the oracle, not on a PegInRequest.

For `Close PegInRequest` the on-chain path is deliberately disabled rather than missing: `peg-in.ak`
implements the `Cancel` branch and reads Config #6, but deployments set that field to a dummy hash
with no registered reward account, so the withdrawal can never be satisfied. Building the off-chain
side is only useful once a real close verifier is deployed.

**Open question:** are these deferred by intent, or a gap? The answer decides whether the checks
should stay numbered as normative requirements or be marked as a future milestone.

---

## 3. No one has verified the checks against the validators

The specification now carries 85 numbered checks across 13 families. Each names the validator that
enforces it. Nobody has confirmed, check by check, that the named validator actually enforces the
stated condition.

An audit of the *implementation-status notes* in 2026-08 found five of fourteen had drifted behind
the code — and every one of them was made stale by work that landed, not by anything being wrong
when written. The numbered checks are newer and have not been through that exercise at all.

This is the largest single piece of assurance work outstanding, at roughly 85 verifications across
three repositories. It is also the one that would tell you whether the implementation is *correct*
rather than merely *present*.

---

## 4. Discovery fields are specified but not implemented

*The Config as the discovery root* requires seven identities to become Config-resident so that an
operator needs only the config NFT policy id: the oracle policy, the TM NFT policy, the registry
policy and its bootstrap outpoint, the ban-list identity, the fault-verifier policies, and the
Treasury state NFT identity. They are recorded as a contract change request; `config.ak` does not
carry them yet.

Two of the seven are trust anchors, so their Config fields are copies for discovery only —
enforcement stays on the validator parameter, and a client detects a false copy by deriving the
reading validator's address from it and checking the instance's UTxOs are there.
