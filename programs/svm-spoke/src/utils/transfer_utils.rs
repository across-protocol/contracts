use crate::{error::SvmError, program::SvmSpoke};
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked};

pub fn transfer_from<'info>(
    from: &InterfaceAccount<'info, TokenAccount>,
    to: &InterfaceAccount<'info, TokenAccount>,
    amount: u64,
    delegate: &UncheckedAccount<'info>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
    delegate_seed_hash: [u8; 32],
) -> Result<()> {
    let (pda, bump) = Pubkey::find_program_address(&[b"delegate", &delegate_seed_hash], &SvmSpoke::id());
    if pda != delegate.key() {
        return err!(SvmError::InvalidDelegatePda);
    }
    let seeds: &[&[u8]] = &[b"delegate".as_ref(), &delegate_seed_hash, &[bump]];
    let signer_seeds: &[&[&[u8]]] = &[seeds];
    let transfer_accounts = TransferChecked {
        from: from.to_account_info(),
        mint: mint.to_account_info(),
        to: to.to_account_info(),
        authority: delegate.to_account_info(),
    };
    let cpi_context = CpiContext::new_with_signer(token_program.to_account_info(), transfer_accounts, signer_seeds);

    transfer_checked(cpi_context, amount, mint.decimals)
}
