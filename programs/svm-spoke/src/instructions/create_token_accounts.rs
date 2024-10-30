use anchor_lang::prelude::*;
use anchor_spl::{ associated_token::{ self, AssociatedToken }, token_interface::{ Mint, TokenInterface } };

use crate::error::SvmError;

#[derive(Accounts)]
pub struct CreateTokenAccounts<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    pub token_program: Interface<'info, TokenInterface>,

    pub associated_token_program: Program<'info, AssociatedToken>,

    pub system_program: Program<'info, System>,
}

pub fn create_token_accounts<'info>(ctx: Context<'_, '_, '_, 'info, CreateTokenAccounts<'info>>) -> Result<()> {
    // Remaining accounts must be passed in pairs of owner and ATA accounts.
    if ctx.remaining_accounts.len() % 2 != 0 {
        return err!(SvmError::InvalidATACreationAccounts);
    }

    for accounts in ctx.remaining_accounts.chunks(2) {
        // We don't need to perform any additional checks as they will be done within ATA creation CPI.
        let authority = &accounts[0];
        let associated_token = &accounts[1];

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
        associated_token::create_idempotent(cpi_ctx)?;
    }

    Ok(())
}
