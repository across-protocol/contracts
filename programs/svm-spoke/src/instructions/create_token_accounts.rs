use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::{self, AssociatedToken},
    token_interface::{Mint, TokenInterface},
};

use crate::error::SvmError;

#[derive(Accounts)]
pub struct CreateTokenAccounts<'info> {
    /// Signer initiating the creation of token accounts.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// Mint of the token for which ATAs will be created.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    /// Token program for creating and managing token accounts.
    pub token_program: Interface<'info, TokenInterface>,

    /// Associated token program required for ATA creation.
    pub associated_token_program: Program<'info, AssociatedToken>,

    /// System program required for account initialization.
    pub system_program: Program<'info, System>,
}

/// Creates associated token accounts (ATAs) for a specified mint and owner(s).
pub fn create_token_accounts<'info>(ctx: Context<'_, '_, '_, 'info, CreateTokenAccounts<'info>>) -> Result<()> {
    // Validate that `remaining_accounts` contains pairs of accounts (owner and ATA).
    if ctx.remaining_accounts.len() % 2 != 0 {
        return err!(SvmError::InvalidATACreationAccounts);
    }

    // Process each pair of accounts.
    for accounts in ctx.remaining_accounts.chunks(2) {
        let authority = &accounts[0]; // Owner account for the ATA.
        let associated_token = &accounts[1]; // Target associated token account.

        // Create the ATA using the associated token program's CPI.
        let cpi_program = ctx.accounts.associated_token_program.to_account_info();
        let cpi_accounts = associated_token::Create {
            payer: ctx.accounts.signer.to_account_info(),
            associated_token: associated_token.to_account_info(),
            authority: authority.to_account_info(),
            mint: ctx.accounts.mint.to_account_info(),
            system_program: ctx.accounts.system_program.to_account_info(),
            token_program: ctx.accounts.token_program.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(cpi_program, cpi_accounts);

        // Use the `create_idempotent` CPI to ensure idempotent behavior (safe to retry).
        associated_token::create_idempotent(cpi_ctx)?;
    }

    Ok(())
}
