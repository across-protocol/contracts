use anchor_lang::prelude::*;

use crate::{
    state::State,
    utils::{initialize_current_time, set_seed},
};

#[derive(Accounts)]
#[instruction(seed: u64)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        init,
        payer = signer,
        space = State::DISCRIMINATOR.len() + State::INIT_SPACE,
        seeds = [b"state", seed.to_le_bytes().as_ref()],
        bump
    )]
    pub state: Account<'info, State>,

    pub system_program: Program<'info, System>,
}

pub fn initialize(
    ctx: Context<Initialize>,
    seed: u64, // Seed used to derive a new state to enable testing to reset between runs.
) -> Result<()> {
    let state = &mut ctx.accounts.state;

    // Set seed and initialize current time. Both enable testing functionality and are no-ops in production.
    set_seed(state, seed)?;
    initialize_current_time(state)?;

    Ok(())
}
