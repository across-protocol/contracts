use anchor_lang::{
    prelude::*,
    solana_program::{program::invoke_signed, system_instruction},
};

use crate::{constants::V5_FILL_PAYER_SEED, event::V5FillFloatWithdrawn};

#[derive(Accounts)]
pub struct WithdrawV5FillPayer<'info> {
    /// The float owner and the only withdrawal destination.
    #[account(mut)]
    pub submitter: Signer<'info>,

    /// CHECK: A data-less, system-owned float PDA derived from the signing submitter.
    #[account(
        mut,
        seeds = [V5_FILL_PAYER_SEED, submitter.key().as_ref()],
        bump
    )]
    pub payer: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Withdraws from the signing submitter's own fill-status rent float. `u64::MAX` drains the live balance.
pub fn withdraw_v5_fill_payer(ctx: Context<WithdrawV5FillPayer>, amount: u64) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    let balance = ctx.accounts.payer.lamports();
    let amount = if amount == u64::MAX { balance } else { amount };
    let seeds: &[&[u8]] = &[V5_FILL_PAYER_SEED, submitter.as_ref(), &[ctx.bumps.payer]];
    invoke_signed(
        &system_instruction::transfer(ctx.accounts.payer.key, &submitter, amount),
        &[
            ctx.accounts.payer.to_account_info(),
            ctx.accounts.submitter.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;
    emit!(V5FillFloatWithdrawn { submitter, amount });
    Ok(())
}
