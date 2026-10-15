use anchor_lang::prelude::*;

use crate::{
    error::SvmError,
    state::{FillStatusAccount, State},
    utils::get_current_time,
};

#[derive(Accounts)]
pub struct CloseFillPda<'info> {
    /// CHECK: The address constraint binds this account to the recorded rent recipient; no signature is required.
    /// For V5 fills, supply the submitter's `["v5_fill_payer", submitter]` PDA recorded in
    /// `fill_status.rent_recipient`; legacy accounts retain the relayer or slow-fill requester address.
    #[account(mut, address = fill_status.rent_recipient @ SvmError::NotRelayer)]
    pub rent_recipient: UncheckedAccount<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    // No need to check seed derivation as this method only evaluates fill deadline that is recorded in this account.
    #[account(mut, close = rent_recipient)]
    pub fill_status: Account<'info, FillStatusAccount>,
}

pub fn close_fill_pda(ctx: Context<CloseFillPda>) -> Result<()> {
    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;

    // Check if the deposit has expired
    if current_time <= ctx.accounts.fill_status.fill_deadline {
        return err!(SvmError::CanOnlyCloseFillStatusPdaIfFillDeadlinePassed);
    }

    Ok(())
}
