# Demo Simplifications

Simplifications of the specificaion to make the testnet demo easier to understand and use. These are not intended to be permanent changes to the specification, but rather temporary simplifications for the purpose of the demo.

## Federation Verification Key

$Y_{federation}$ = 02b1e15a532a4e816ec75af608256b0808e36fb7d22560605178850885e53f2854

## Pegin Taproot Script

RETIRED (WI-081). This entry specified a ONE-leaf peg-in tree with $Y_{federation}$ as the
internal key. Both halves of that are now wrong:

- The internal key is $Y_{51}$, the FROST group key, so the 51% quorum sweeps by key path.
- The tree has TWO leaves — a $Y_{federation}$ + CSV emergency sweep alongside the depositor
  refund — per spec §Peg-in Taproot tree. Dropping the federation leaf removed the bridge's
  recovery path for a deposit the quorum cannot sweep.

The simplification survived as long as it did because this file also pinned
$Y_{federation}$ to the FROST group key's own value, which made "internal key = $Y_{fed}$"
and "internal key = $Y_{51}$" the same bytes and hid the difference. See the spec section for
the real tree; the reference implementation is `pegin_deposit.py::pegin_outputkey`.

## Treasury Taproot

$Y_{federation}$

## Cardano Treasury Movement UTxO

Minting policy: 186e32faa80a26810392fda6d559c7ed4721a65ce1c9d4ef3e1c87b4 (alwaysOK script for demo purposes)
Address: ScriptCredential(policyId), stake credential: None
Address Preprod: addr_test1wqvxuvh64q9zdqgrjt76d42eclk5wgdxtnsun4808cwg0dqxy2mj0
Asset Name: "TMTx"

Datum: Constr 0 [TMTx bytestring]

## fBTC minting policy

1. Check TMTx inclusion
2. Check Alice's signature
3. Check PIR amount to mint
4. Check PIR non-inclusion? (Raul, is this necessary?)
5. Check update of completed PIRs (Raul, is this necessary?)
