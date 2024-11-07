use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct ClaimAccount {
    pub amount: u64,
    pub initializer: Pubkey,
}

// This implements the following Anchor account constraints when parsing remaining account as a claim account:
// #[account(
//     mut,
//     seeds = [b"claim_account", mint.key().as_ref(), refund_address.key().as_ref()],
//     bump
// )]
// pub claim_account: Account<'info, ClaimAccount>,
// Note: Account name should be appended to any possible errors by the caller.
impl<'info> ClaimAccount {
    pub fn try_from(
        account_info: &'info AccountInfo<'info>,
        mint: &Pubkey,
        refund_address: &Pubkey,
    ) -> Result<Account<'info, ClaimAccount>> {
        // Checks ownership on deserialization for the ClaimAccount.
        let claim_account: Account<'info, ClaimAccount> = Account::try_from(account_info)?;

        // Checks the PDA is derived from mint and refund address keys.
        let (pda_address, _bump) =
            Pubkey::find_program_address(&[b"claim_account", mint.as_ref(), refund_address.as_ref()], &crate::ID);
        if account_info.key() != pda_address {
            return Err(Error::from(ErrorCode::ConstraintSeeds).with_pubkeys((claim_account.key(), pda_address)));
        }

        // Checks if the claim account is writable.
        if !account_info.is_writable {
            return Err(Error::from(ErrorCode::ConstraintMut));
        }

        Ok(claim_account)
    }
}
