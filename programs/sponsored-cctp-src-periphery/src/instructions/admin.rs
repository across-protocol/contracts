use anchor_lang::prelude::*;

use crate::{
    error::SvmError,
    event::QuoteSignerSet,
    program,
    state::State,
    utils::{initialize_current_time, set_seed},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(params: InitializeParams)]
pub struct Initialize<'info> {
    #[account(
        mut,
        address = program_data.upgrade_authority_address.unwrap_or_default() @ SvmError::NotUpgradeAuthority
    )]
    pub signer: Signer<'info>,

    #[account(
        init,
        payer = signer,
        space = State::DISCRIMINATOR.len() + State::INIT_SPACE,
        seeds = [b"state", params.seed.to_le_bytes().as_ref()],
        bump
    )]
    pub state: Account<'info, State>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    // This is duplicate of program account added by event_cpi, but we need it to access its programdata_address.
    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct InitializeParams {
    pub seed: u64,
    pub local_domain: u32,
    pub quote_signer: Pubkey,
}

pub fn initialize(ctx: Context<Initialize>, params: &InitializeParams) -> Result<()> {
    let state = &mut ctx.accounts.state;

    // Set seed and initialize current time. Both enable testing functionality and are no-ops in production.
    set_seed(state, params.seed)?;
    initialize_current_time(state)?;

    // Set immutable local CCTP domain.
    state.local_domain = params.local_domain;

    // Set and log initial quote signer.
    state.quote_signer = params.quote_signer;
    emit_cpi!(QuoteSignerSet { old_quote_signer: Pubkey::default(), new_quote_signer: params.quote_signer });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetQuoteSigner<'info> {
    #[account(
        mut,
        address = program_data.upgrade_authority_address.unwrap_or_default() @ SvmError::NotUpgradeAuthority
    )]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    // This is duplicate of program account added by event_cpi, but we need it to access its programdata_address.
    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SetQuoteSignerParams {
    pub quote_signer: Pubkey,
}

// This also allows setting the quote signer to Pubkey::default() to effectively disable deposits.
pub fn set_quote_signer(ctx: Context<SetQuoteSigner>, params: &SetQuoteSignerParams) -> Result<()> {
    let state = &mut ctx.accounts.state;

    // Set and log old/new quote signer.
    let old_quote_signer = state.quote_signer;
    state.quote_signer = params.quote_signer;
    emit_cpi!(QuoteSignerSet { old_quote_signer, new_quote_signer: params.quote_signer });

    Ok(())
}
