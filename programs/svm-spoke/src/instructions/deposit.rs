// Note: The `svm-spoke` does not support `speedUpV3Deposit` and `fillV3RelayWithUpdatedDeposit` due to cryptographic
// incompatibilities between Solana (Ed25519) and Ethereum (ECDSA secp256k1). Specifically, Solana wallets cannot
// generate ECDSA signatures required for Ethereum verification. As a result, speed-up functionality on Solana is not
// implemented. For more details, refer to the documentation: https://docs.across.to

use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    constants::{MAX_EXCLUSIVITY_PERIOD_SECONDS, ZERO_DEPOSIT_ID},
    error::{CommonError, SvmError},
    event::FundsDeposited,
    state::{Delegate, Route, State},
    utils::{get_current_time, get_unsafe_deposit_id, transfer_from},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    #[account(
        mut,
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_deposits @ CommonError::DepositsArePaused
    )]
    pub state: Account<'info, State>,

    #[account(
        mut,
        seeds = [
        b"delegate",
        state.seed.to_le_bytes().as_ref(),
        input_token.as_ref(),
        output_token.as_ref(),
        input_amount.to_le_bytes().as_ref(),
        output_amount.to_le_bytes().as_ref(),
        destination_chain_id.to_le_bytes().as_ref()
        ],
        bump
    )]
    pub delegate: Account<'info, Delegate>,

    #[account(
        seeds = [b"route", input_token.as_ref(), state.seed.to_le_bytes().as_ref(), destination_chain_id.to_le_bytes().as_ref()],
        bump,
        constraint = route.enabled @ CommonError::DisabledRoute
    )]
    pub route: Account<'info, Route>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = depositor,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state, // Ensure owner is the state as tokens are sent here on deposit.
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mint::token_program = token_program,
        constraint = mint.key() == input_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn _deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_id: [u8; 32],
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let current_time = get_current_time(state)?;

    if current_time.checked_sub(quote_timestamp).unwrap_or(u32::MAX) > state.deposit_quote_time_buffer {
        return err!(CommonError::InvalidQuoteTimestamp);
    }
    if fill_deadline > current_time + state.fill_deadline_buffer {
        return err!(CommonError::InvalidFillDeadline);
    }

    let mut exclusivity_deadline = exclusivity_parameter;
    if exclusivity_deadline > 0 {
        if exclusivity_deadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS {
            exclusivity_deadline += current_time;
        }
        if exclusive_relayer == Pubkey::default() {
            return err!(CommonError::InvalidExclusiveRelayer);
        }
    }

    // Reassemble delegate PDA signer seeds
    let state_seed_bytes = state.seed.to_le_bytes();
    let input_amount_bytes = input_amount.to_le_bytes();
    let output_amount_bytes = output_amount.to_be_bytes();
    let destination_chain_id_bytes = destination_chain_id.to_le_bytes();
    let base_seeds: &[&[u8]] = &[
        b"delegate",
        &state_seed_bytes,
        input_token.as_ref(),
        output_token.as_ref(),
        &input_amount_bytes,
        &output_amount_bytes,
        &destination_chain_id_bytes,
    ];
    let (_pda, delegate_bump) = Pubkey::find_program_address(base_seeds, ctx.program_id);
    let bump_slice = [delegate_bump];
    let full_seeds: Vec<&[u8]> = base_seeds
        .iter()
        .copied()
        .chain(std::iter::once(&bump_slice[..]))
        .collect();

    // Relayer must have delegated output_amount to the delegate PDA
    transfer_from(
        &ctx.accounts.depositor_token_account,
        &ctx.accounts.vault,
        input_amount,
        &ctx.accounts.delegate,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
        full_seeds.as_slice(),
    )?;

    let mut applied_deposit_id = deposit_id;
    // If deposit_id is zero, update state.number_of_deposits.
    if deposit_id == ZERO_DEPOSIT_ID {
        state.number_of_deposits += 1;
        applied_deposit_id[28..].copy_from_slice(&state.number_of_deposits.to_be_bytes());
    }

    emit_cpi!(FundsDeposited {
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        deposit_id: applied_deposit_id,
        quote_timestamp,
        fill_deadline,
        exclusivity_deadline,
        depositor,
        recipient,
        exclusive_relayer,
        message,
    });

    Ok(())
}

pub fn deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    _deposit(
        ctx,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        ZERO_DEPOSIT_ID, // ZERO_DEPOSIT_ID informs internal function to use state.number_of_deposits as id.
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
    )?;

    Ok(())
}

pub fn deposit_now(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    fill_deadline_offset: u32,
    exclusivity_period: u32,
    message: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let current_time = get_current_time(state)?;
    deposit(
        ctx,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        current_time,
        current_time + fill_deadline_offset,
        exclusivity_period,
        message,
    )?;

    Ok(())
}

pub fn unsafe_deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_nonce: u64,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    // Calculate the unsafe deposit ID as a [u8; 32]
    let deposit_id = get_unsafe_deposit_id(ctx.accounts.signer.key(), depositor, deposit_nonce);
    _deposit(
        ctx,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        deposit_id,
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
    )?;

    Ok(())
}
