pub const btc_asset_name = ""

pub const registered_spos_asset_name = ""

//spec [CFG-7]: the Config NFT asset name is a protocol constant, not a
//validator parameter. A parameter here has no safe failure mode: a deployment
//that passes another name leaves treasury.ak looking for a token that does not
//exist, and its Retire branch fails with it, so the Treasury state UTxO can
//never be spent again.
pub const config_nft_asset_name = "BIFCFG"

//Asset name of the Treasury state NFT (spec §Treasury state UTxO). A constant,
//not sha256 of the bootstrap outpoint: uniqueness comes from the one-shot
//outpoint baked into the policy id.
pub const treasury_info_nft_asset_name = "BFRTRY"

pub const completed_peg_ins_root_asset_name = "CPI"

//No completed_peg_outs_root_asset_name ("CPO") any more: the CPO trie UTxO is
//replaced by the bridge state singleton, whose cpo_root peg-out reads per
//[CPO-13].

//Asset name of the bridge state singleton NFT (spec §Singleton validator).
pub const bridge_state_asset_name = "BSS"

//spec [CFG-1]: the bridged-token asset name is a protocol constant, not a
//Config field. One token is one satoshi.
pub const bridged_token_asset_name = "fSAT"
