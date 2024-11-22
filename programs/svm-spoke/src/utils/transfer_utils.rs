use anchor_lang::prelude::*;
use anchor_spl::token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked};

use crate::State;

pub fn transfer_from<'info>(
    from: &InterfaceAccount<'info, TokenAccount>,
    to: &InterfaceAccount<'info, TokenAccount>,
    amount: u64,
    state: &Account<'info, State>,
    state_bump: u8,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let transfer_accounts = TransferChecked {
        from: from.to_account_info(),
        mint: mint.to_account_info(),
        to: to.to_account_info(),
        authority: state.to_account_info(),
    };

    let state_seed_bytes = state.seed.to_le_bytes();
    let seeds = &[b"state", state_seed_bytes.as_ref(), &[state_bump]];
    let signer_seeds = &[&seeds[..]];

    let cpi_context = CpiContext::new_with_signer(token_program.to_account_info(), transfer_accounts, signer_seeds);

    transfer_checked(cpi_context, amount, mint.decimals)
}
