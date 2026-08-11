/// The completed-peg-ins (CPI) trie singleton's datum: one MPF root, keyed by
/// `peg_in_utxo_id`, recording every deposit that has already issued fBTC.
///
/// It lives in `lib/` rather than beside its validator because BOTH read it:
/// `completed-peg-ins-merkle-tree.ak` pins the genesis datum with it, and
/// `bifrost/utils.get_mpf_from_output` decodes the live one. One definition, so
/// the two can never describe different shapes.
///
/// Arity is exact by construction — `expect trie: CompletedPegInsTrieDatum`
/// checks the constructor tag and the field count. That is the rule for every
/// datum in this tree except `ConfigDatum`: only the Config UTxO has to stay
/// append-extensible, because every contract is parameterized by the config NFT
/// and so the Config alone cannot be replaced. Everything else sits behind a
/// Config-updatable script hash, so a datum change ships as a new validator
/// plus a Config Update — and pinning the shape costs nothing.
pub type CompletedPegInsTrieDatum {
  root: ByteArray,
}
