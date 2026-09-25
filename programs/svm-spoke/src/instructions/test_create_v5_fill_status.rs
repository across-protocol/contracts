use anchor_lang::prelude::*;

use crate::v5::fill_status::{create_v5_fill_status_account, V5FillStatusPdas};

#[derive(Accounts)]
pub struct TestCreateV5FillStatus<'info> {
    pub submitter: Signer<'info>,

    /// CHECK: Validated by `create_v5_fill_status_account` against the submitter-scoped payer PDA.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,

    /// CHECK: Validated by `create_v5_fill_status_account` against the relay-scoped fill-status PDA.
    #[account(mut)]
    pub fill_status: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Test-only entrypoint for focused coverage of the PDA-signed account-creation lifecycle.
pub fn test_create_v5_fill_status(
    ctx: Context<TestCreateV5FillStatus>,
    relay_hash: [u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    let pdas = V5FillStatusPdas::derive(&submitter, &relay_hash);
    let pending_fill_status = create_v5_fill_status_account(
        &ctx.accounts.payer.to_account_info(),
        &ctx.accounts.fill_status.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &pdas,
    )?;
    pending_fill_status.write_filled(fill_deadline)
}
