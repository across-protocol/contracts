use anchor_lang::prelude::*;

use crate::{
    state::State,
    utils::{get_self_authority_pda, get_v3_relay_hash},
    RelayData,
};

pub fn is_local_or_remote_owner(signer: &Signer, state: &Account<State>) -> bool {
    signer.key() == state.owner || signer.key() == get_self_authority_pda()
}

pub fn is_relay_hash_valid(relay_hash: &[u8; 32], relay_data: &RelayData, state: &Account<State>) -> bool {
    relay_hash == &get_v3_relay_hash(relay_data, state.chain_id)
}
