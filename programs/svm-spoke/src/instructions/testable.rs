use anchor_lang::prelude::*;

use crate::state::State;

#[derive(Accounts)]
pub struct SetCurrentTime<'info> {
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub signer: Signer<'info>,
}

pub fn set_current_time(ctx: Context<SetCurrentTime>, new_time: u32) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.set_current_time(new_time) // Stores new time in test build (error in production).
}
