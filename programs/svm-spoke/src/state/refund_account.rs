use anchor_lang::prelude::*;
use anchor_spl::token_interface::TokenAccount;

use crate::error::CustomError;

#[account]
#[derive(InitSpace)]
pub struct ClaimAccount {
    pub amount: u64,
    pub initializer: Pubkey,
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
    // a token account and if that fails, it tries to parse it as a claim account.
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

        Self::try_token_account_from_account_info(
            refund_account_info,
            expected_token_account,
            expected_mint,
            token_program,
        )
        .map(Self::TokenAccount)
        .or_else(|| {
            Self::try_claim_account_from_account_info(
                refund_account_info,
                expected_mint,
                expected_token_account,
            )
            .map(Self::ClaimAccount)
        })
        .ok_or_else(|| {
            error::Error::from(CustomError::InvalidRefund)
                .with_account_name(&format!("remaining_accounts[{}]", index))
        })
    }

    // This implements the following Anchor account constraints when parsing remaining account as a token account:
    // #[account(
    //     mut,
    //     address = expected_token_account @ CustomError::InvalidRefund,
    //     token::mint = expected_mint,
    //     token::token_program = token_program
    // )]
    // pub token_account: InterfaceAccount<'info, TokenAccount>,
    // Note: All errors are ignored and Option is returned as we do not log them anyway due to memory constraints.
    fn try_token_account_from_account_info(
        account_info: &'info AccountInfo<'info>,
        expected_token_account: &Pubkey,
        expected_mint: &Pubkey,
        token_program: &Pubkey,
    ) -> Option<InterfaceAccount<'info, TokenAccount>> {
        // Checks ownership on deserialization for the TokenAccount interface.
        let token_account: InterfaceAccount<'info, TokenAccount> =
            InterfaceAccount::try_from(account_info).ok()?;

        // Checks if the token account is writable.
        if !account_info.is_writable {
            return None;
        }

        // Checks the token address matches.
        if account_info.key != expected_token_account {
            return None;
        }

        // Checks if the token account is associated with the expected mint.
        if &token_account.mint != expected_mint {
            return None;
        }

        // Checks ownership by specific token program.
        if account_info.owner != token_program {
            return None;
        }

        Some(token_account)
    }

    // This implements the following Anchor account constraints when parsing remaining account as a claim account:
    // #[account(
    //     mut,
    //     seeds = [b"claim_account", mint.key().as_ref(), token_account.key().as_ref()],
    //     bump
    // )]
    // pub claim_account: Account<'info, ClaimAccount>,
    // Note: All errors are ignored and Option is returned as we do not log them anyway due to memory constraints.
    fn try_claim_account_from_account_info(
        account_info: &'info AccountInfo<'info>,
        mint: &Pubkey,
        token_account: &Pubkey,
    ) -> Option<Account<'info, ClaimAccount>> {
        // Checks ownership on deserialization for the ClaimAccount.
        let claim_account: Account<'info, ClaimAccount> = Account::try_from(account_info).ok()?;

        // Checks the PDA is derived from mint and token account keys.
        let (pda_address, _bump) = Pubkey::find_program_address(
            &[b"claim_account", mint.as_ref(), token_account.as_ref()],
            &crate::ID,
        );
        if account_info.key() != pda_address {
            return None;
        }

        // Checks if the claim account is writable.
        if !account_info.is_writable {
            return None;
        }

        Some(claim_account)
    }
}
