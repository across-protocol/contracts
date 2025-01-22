use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    state::State,
    utils::{get_self_authority_pda, get_v3_relay_hash},
    V3RelayData,
};

pub fn is_local_or_remote_owner(signer: &Signer, state: &Account<State>) -> bool {
    signer.key() == state.owner || signer.key() == get_self_authority_pda()
}

pub fn is_relay_hash_valid(relay_hash: &[u8; 32], relay_data: &V3RelayData, state: &Account<State>) -> bool {
    relay_hash == &get_v3_relay_hash(relay_data, state.chain_id)
}

// Implements the same underlying logic as in Anchor's associated_token constraint macro, except for token_program_check
// as that would duplicate Anchor's token constraint macro that the caller already uses.
// https://github.com/coral-xyz/anchor/blob/e6d7dafe12da661a36ad1b4f3b5970e8986e5321/lang/syn/src/codegen/accounts/constraints.rs#L1132
pub fn is_valid_associated_token_account(
    token_account: &InterfaceAccount<TokenAccount>,
    mint: &InterfaceAccount<Mint>,
    token_program: &Interface<TokenInterface>,
    authority: &Pubkey,
) -> bool {
    &token_account.owner == authority
        && token_account.key()
            == get_associated_token_address_with_program_id(authority, &mint.key(), &token_program.key())
}
