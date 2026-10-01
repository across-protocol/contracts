use crate::{error::SvmError, program::SvmSpoke};
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{transfer_checked, TransferChecked};

pub fn transfer_from<'info>(
    accounts: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    amount: u64,
    mint_decimals: u8,
    delegate_seed: &[u8],
) -> Result<()> {
    let (delegate, bump) = Pubkey::find_program_address(&[delegate_seed], &SvmSpoke::id());
    if delegate != accounts.authority.key() {
        return err!(SvmError::InvalidDelegatePda);
    }

    let bump_seed = [bump];
    let signer_seeds: &[&[u8]] = &[delegate_seed, &bump_seed];
    let signer_seeds = [signer_seeds];

    transfer_checked(CpiContext::new_with_signer(token_program, accounts, &signer_seeds), amount, mint_decimals)
}
