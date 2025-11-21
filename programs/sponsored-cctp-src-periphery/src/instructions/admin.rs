use anchor_lang::{
    prelude::*,
    system_program::{self, Transfer},
};
use anchor_spl::token_interface::Mint;

use crate::{
    error::SvmError,
    event::{MinimumDepositAmountSet, SignerSet, WithdrawnRentFund},
    program,
    state::{MinimumDeposit, State},
    utils::initialize_current_time,
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

    #[account(init, payer = signer, space = State::DISCRIMINATOR.len() + State::INIT_SPACE, seeds = [b"state"], bump)]
    pub state: Account<'info, State>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    // This is duplicate of program account added by event_cpi, but we need it to access its programdata_address.
    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct InitializeParams {
    pub source_domain: u32,
    pub signer: Pubkey,
}

pub fn initialize(ctx: Context<Initialize>, params: &InitializeParams) -> Result<()> {
    let state = &mut ctx.accounts.state;

    // Persist the seed bump.
    state.bump = ctx.bumps.state;

    // Set current time in test mode (no-op in production).
    initialize_current_time(state)?;

    // Set immutable source CCTP domain.
    state.source_domain = params.source_domain;

    // Set and log initial quote signer.
    state.signer = params.signer;
    emit_cpi!(SignerSet { old_signer: Pubkey::default(), new_signer: params.signer });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetSigner<'info> {
    #[account(
        mut,
        address = program_data.upgrade_authority_address.unwrap_or_default() @ SvmError::NotUpgradeAuthority
    )]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state"], bump = state.bump)]
    pub state: Account<'info, State>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    // This is duplicate of program account added by event_cpi, but we need it to access its programdata_address.
    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SetSignerParams {
    pub new_signer: Pubkey,
}

// Setting the quote signer to invalid address, including Pubkey::default(), would effectively disable deposits.
pub fn set_signer(ctx: Context<SetSigner>, params: &SetSignerParams) -> Result<()> {
    let state = &mut ctx.accounts.state;

    let old_signer = state.signer;
    if params.new_signer == old_signer {
        return err!(SvmError::SignerUnchanged);
    }

    // Set and log old/new quote signer.
    state.signer = params.new_signer;
    emit_cpi!(SignerSet { old_signer, new_signer: params.new_signer });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct WithdrawRentFund<'info> {
    #[account(
        mut,
        address = program_data.upgrade_authority_address.unwrap_or_default() @ SvmError::NotUpgradeAuthority
    )]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    /// CHECK: Upgrade authority can withdraw from rent_fund to any account.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    // This is duplicate of program account added by event_cpi, but we need it to access its programdata_address.
    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct WithdrawRentFundParams {
    pub amount: u64,
}

pub fn withdraw_rent_fund(ctx: Context<WithdrawRentFund>, params: &WithdrawRentFundParams) -> Result<()> {
    if params.amount == 0 {
        return err!(SvmError::AmountNotPositive);
    }

    let cpi_accounts =
        Transfer { from: ctx.accounts.rent_fund.to_account_info(), to: ctx.accounts.recipient.to_account_info() };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_ctx =
        CpiContext::new_with_signer(ctx.accounts.system_program.to_account_info(), cpi_accounts, rent_fund_seeds);
    system_program::transfer(cpi_ctx, params.amount)?;

    emit_cpi!(WithdrawnRentFund { amount: params.amount, recipient: ctx.accounts.recipient.key() });

    Ok(())
}

#[derive(Accounts)]
pub struct SetMinimumDepositAmount<'info> {
    #[account(
        mut,
        address = program_data.upgrade_authority_address.unwrap_or_default() @ SvmError::NotUpgradeAuthority
    )]
    pub signer: Signer<'info>,

    #[account(
        init_if_needed,
        payer = signer,
        space = MinimumDeposit::DISCRIMINATOR.len() + MinimumDeposit::INIT_SPACE,
        seeds = [b"minimum_deposit", burn_token.key().as_ref()],
        bump
    )]
    pub minimum_deposit: Account<'info, MinimumDeposit>,

    #[account()]
    pub burn_token: InterfaceAccount<'info, Mint>,

    #[account(address = this_program.programdata_address()?.unwrap_or_default() @ SvmError::InvalidProgramData)]
    pub program_data: Account<'info, ProgramData>,

    pub this_program: Program<'info, program::SponsoredCctpSrcPeriphery>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SetMinimumDepositAmountParams {
    pub amount: u64,
}

pub fn set_minimum_deposit_amount(
    ctx: Context<SetMinimumDepositAmount>,
    params: &SetMinimumDepositAmountParams,
) -> Result<()> {
    let minimum_deposit = &mut ctx.accounts.minimum_deposit;

    // Persist the PDA seed bump. This overwrites it if the account already exists, but it should be the same value.
    minimum_deposit.bump = ctx.bumps.minimum_deposit;

    // Set and log the new minimum deposit amount for the burn token.
    minimum_deposit.amount = params.amount;
    emit!(MinimumDepositAmountSet { amount: params.amount, burn_token: ctx.accounts.burn_token.key() });

    Ok(())
}
