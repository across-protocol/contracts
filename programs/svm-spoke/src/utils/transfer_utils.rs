use crate::{error::SvmError, program::SvmSpoke};
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked};

#[derive(Clone, Copy)]
pub enum DelegatePda {
    UniqueHash([u8; 32]),
    FunctionSeed(&'static [u8]),
}

pub fn transfer_from<'info>(
    from: &InterfaceAccount<'info, TokenAccount>,
    to: &InterfaceAccount<'info, TokenAccount>,
    amount: u64,
    delegate: &UncheckedAccount<'info>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
    delegate_seed_hash: [u8; 32],
) -> Result<()> {
    transfer_from_with_delegate(
        TransferChecked {
            from: from.to_account_info(),
            mint: mint.to_account_info(),
            to: to.to_account_info(),
            authority: delegate.to_account_info(),
        },
        token_program.to_account_info(),
        amount,
        mint.decimals,
        DelegatePda::UniqueHash(delegate_seed_hash),
    )
}

pub fn transfer_from_with_delegate<'info>(
    accounts: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    amount: u64,
    mint_decimals: u8,
    delegate_pda: DelegatePda,
) -> Result<()> {
    // Right-align both layouts so one-seed PDAs skip the empty placeholder at index 0.
    let (delegate_seeds, start): ([&[u8]; 2], usize) = match &delegate_pda {
        DelegatePda::UniqueHash(hash) => ([b"delegate".as_ref(), hash.as_ref()], 0),
        DelegatePda::FunctionSeed(seed) => ([&[], *seed], 1),
    };
    let (delegate, bump) = Pubkey::find_program_address(&delegate_seeds[start..], &SvmSpoke::id());
    if delegate != accounts.authority.key() {
        return err!(SvmError::InvalidDelegatePda);
    }

    let bump_seed = [bump];
    // Reuse the same offset after appending the bump, without allocating a seed vector.
    let signer_seeds = [delegate_seeds[0], delegate_seeds[1], bump_seed.as_ref()];
    let signer_seeds = [&signer_seeds[start..]];

    transfer_checked(CpiContext::new_with_signer(token_program, accounts, &signer_seeds), amount, mint_decimals)
}
