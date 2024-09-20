use anchor_lang::prelude::*;

use crate::{error::CustomError, state::State};

#[derive(Accounts)]
pub struct SetCurrentTime<'info> {
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub signer: Signer<'info>,
}

pub fn set_current_time(ctx: Context<SetCurrentTime>, new_time: u32) -> Result<()> {
    let state = &mut ctx.accounts.state;
    require!(state.current_time != 0, CustomError::CannotSetCurrentTime); // Ensure current_time is not zero
    state.current_time = new_time;
    Ok(())
}
