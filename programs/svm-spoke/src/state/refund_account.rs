use anchor_lang::prelude::*;
use anchor_spl::token_interface::TokenAccount;

use crate::error::CustomError;

#[account]
#[derive(InitSpace)]
pub struct ClaimAccount {
    pub amount: u64,
}

// When executing relayer refund leaf, refund accounts are passed as remaining accounts and can hold either a regular
// token account or a claim account. This enum is used to differentiate between the two types.
pub enum RefundAccount<'info> {
    TokenAccount(InterfaceAccount<'info, TokenAccount>),
    ClaimAccount(Account<'info, ClaimAccount>),
}

impl<'c, 'info> RefundAccount<'info>
where
    'c: 'info,
{
    // This function is used to parse a refund account from the remaining accounts list. It first tries to parse it as
    // a token account and if that fails, it falls back to a claim account.
    pub fn try_from_remaining_account(
        remaining_accounts: &'c [AccountInfo<'info>],
        index: usize,
        expected_token_account: &Pubkey,
        expected_mint: &Pubkey,
        token_program: &Pubkey,
    ) -> Result<Self> {
        let refund_account_info = remaining_accounts
            .get(index)
            .ok_or(ErrorCode::AccountNotEnoughKeys)?;

        let token_result = Self::try_token_account_from_account_info(
            refund_account_info,
            expected_token_account,
            expected_mint,
            token_program,
        );

        match token_result {
            Ok(token_account) => Ok(Self::TokenAccount(token_account)),
            Err(token_error) => {
                token_error.log(); // Log token account parsing error for debugging, but do not revert yet.

                let claim_result = Self::try_claim_account_from_account_info(
                    refund_account_info,
                    expected_mint,
                    expected_token_account,
                );

                match claim_result {
                    Ok(claim_account) => Ok(Self::ClaimAccount(claim_account)),
                    Err(claim_error) => {
                        claim_error.log(); // Log claim account parsing error for debugging.

                        // Separate error to include remaining accounts index when reverting.
                        Err(error::Error::from(CustomError::InvalidRefund)
                            .with_account_name(&format!("remaining_accounts[{}]", index)))
                    }
                }
            }
        }
    }

    // This implements the following Anchor account constraints when parsing remaining account as a token account:
    // #[account(
    //     mut,
    //     address = expected_token_account @ CustomError::InvalidRefund,
    //     token::mint = expected_mint,
    //     token::token_program = token_program
    // )]
    // pub token_account: InterfaceAccount<'info, TokenAccount>,
    fn try_token_account_from_account_info(
        account_info: &'info AccountInfo<'info>,
        expected_token_account: &Pubkey,
        expected_mint: &Pubkey,
        token_program: &Pubkey,
    ) -> Result<InterfaceAccount<'info, TokenAccount>> {
        // Checks ownership on deserialization for the TokenAccount interface.
        let token_account: InterfaceAccount<'info, TokenAccount> =
            InterfaceAccount::try_from(account_info)?;

        // Checks if the token account is writable.
        if !account_info.is_writable {
            return Err(error::ErrorCode::ConstraintMut.into());
        }

        // Checks the token address matches.
        if account_info.key != expected_token_account {
            return Err(error::Error::from(CustomError::InvalidRefund)
                .with_pubkeys((account_info.key(), expected_token_account.to_owned())));
        }

        // Checks if the token account is associated with the expected mint.
        if &token_account.mint != expected_mint {
            return Err(error::ErrorCode::ConstraintTokenMint.into());
        }

        // Checks ownership by specific token program.
        if account_info.owner != token_program {
            return Err(error::ErrorCode::ConstraintTokenTokenProgram.into());
        }

        Ok(token_account)
    }

    // This implements the following Anchor account constraints when parsing remaining account as a claim account:
    // #[account(
    //     mut,
    //     seeds = [b"claim_account", mint.key().as_ref(), token_account.key().as_ref()],
    //     bump
    // )]
    // pub claim_account: Account<'info, ClaimAccount>,
    fn try_claim_account_from_account_info(
        account_info: &'info AccountInfo<'info>,
        mint: &Pubkey,
        token_account: &Pubkey,
    ) -> Result<Account<'info, ClaimAccount>> {
        // Checks ownership on deserialization for the ClaimAccount.
        let claim_account: Account<'info, ClaimAccount> = Account::try_from(account_info)?;

        // Checks the PDA is derived from mint and token account keys.
        let (pda_address, _bump) = Pubkey::find_program_address(
            &[b"claim_account", mint.as_ref(), token_account.as_ref()],
            &crate::ID,
        );
        if account_info.key() != pda_address {
            return Err(error::Error::from(error::ErrorCode::ConstraintSeeds)
                .with_pubkeys((account_info.key(), pda_address)));
        }

        // Checks if the claim account is writable.
        if !account_info.is_writable {
            return Err(error::ErrorCode::ConstraintMut.into());
        }

        Ok(claim_account)
    }
}
