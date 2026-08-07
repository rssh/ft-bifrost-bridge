pub const btc_asset_name = ""

pub const registered_spos_asset_name = ""

pub const treasury_info_nft_asset_name = ""

pub const completed_peg_ins_root_asset_name = "CPI"

//No completed_peg_outs_root_asset_name ("CPO") any more: the CPO trie UTxO is
//replaced by the bridge state singleton, whose cpo_root peg-out reads per
//[CPO-13].

//Asset name of the bridge state singleton NFT (spec §Singleton validator).
pub const bridge_state_asset_name = "BSS"

//spec [CFG-1]: the bridged-token asset name is a protocol constant, not a
//Config field. One token is one satoshi.
pub const bridged_token_asset_name = "fSAT"
