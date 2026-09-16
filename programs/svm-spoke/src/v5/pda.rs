use anchor_lang::prelude::*;

use crate::{
    constants::{FILL_STATUS_SEED, GATEWAY_DISPATCH_AUTHORITY, V5_FILL_PAYER_SEED},
    error::V5Error,
    ID,
};

pub fn require_v5_delegate_allowance(allowance: u64, amount: u64) -> Result<()> {
    require!(allowance >= amount, V5Error::InsufficientDelegateAllowance);
    Ok(())
}

pub fn derive_v5_fill_payer(submitter: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[V5_FILL_PAYER_SEED, submitter.as_ref()], &ID)
}

pub fn derive_fill_status(relay_hash: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[FILL_STATUS_SEED, relay_hash], &ID)
}

pub fn require_gateway_dispatch_authority(account: &AccountInfo) -> Result<()> {
    require!(account.is_signer && *account.key == GATEWAY_DISPATCH_AUTHORITY, V5Error::InvalidDispatchAuthority);
    Ok(())
}

/// Resolve branch-specific accounts by authenticated key, never by submitter-controlled position.
pub fn find_v5_account<'a, 'info>(
    accounts: &'a [AccountInfo<'info>],
    expected: &Pubkey,
    writable: bool,
) -> Result<&'a AccountInfo<'info>> {
    let account = accounts
        .iter()
        .find(|account| account.key == expected)
        .ok_or_else(|| error!(V5Error::MissingAccount))?;
    require!(!writable || account.is_writable, V5Error::InvalidAccountMutability);
    Ok(account)
}
