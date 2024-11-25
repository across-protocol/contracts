use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    constants::{MAX_EXCLUSIVITY_PERIOD_SECONDS, ZERO_DEPOSIT_ID},
    error::{CommonError, SvmError},
    event::V3FundsDeposited,
    state::{Route, State},
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
pub struct DepositV3<'info> {
    /// Signer initiating the deposit.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// State account containing global configurations and deposit tracking.
    #[account(
        mut,
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_deposits @ CommonError::DepositsArePaused
    )]
    pub state: Account<'info, State>,

    /// Route PDA storing the routing configuration for the deposit.
    #[account(
        seeds = [b"route", input_token.as_ref(), state.seed.to_le_bytes().as_ref(), destination_chain_id.to_le_bytes().as_ref()],
        bump,
        constraint = route.enabled @ CommonError::DisabledRoute
    )]
    pub route: Account<'info, Route>,

    /// Token account of the depositor.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = depositor,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    /// Vault PDA for storing deposited tokens, owned by the state.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// Mint of the deposited token.
    #[account(
        mint::token_program = token_program,
        constraint = mint.key() == input_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    /// Token program for CPI interactions.
    pub token_program: Interface<'info, TokenInterface>,
}

/// Internal function for processing a deposit.
///
/// ### Parameters:
/// - `ctx`: The context for the deposit.
/// - `depositor`: The depositor's public key.
/// - `recipient`: The recipient's public key.
/// - `input_token`: The input token's public key.
/// - `output_token`: The output token's public key.
/// - `input_amount`: The amount of input tokens to deposit.
/// - `output_amount`: The amount of output tokens to deposit.
/// - `destination_chain_id`: The destination chain ID.
/// - `exclusive_relayer`: The exclusive relayer's public key.
/// - `deposit_id`: Identifier for the deposit.
/// - `quote_timestamp`: Timestamp when the quote was provided.
/// - `fill_deadline`: Deadline by which the deposit must be filled.
/// - `exclusivity_parameter`: Defines the exclusivity period.
/// - `message`: Arbitrary message attached to the deposit event.
pub fn _deposit_v3(
    ctx: Context<DepositV3>,
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

    // Validate quote timestamp against the state buffer.
    if current_time.checked_sub(quote_timestamp).unwrap_or(u32::MAX) > state.deposit_quote_time_buffer {
        return err!(CommonError::InvalidQuoteTimestamp);
    }

    // Validate fill deadline constraints.
    if fill_deadline < current_time || fill_deadline > current_time + state.fill_deadline_buffer {
        return err!(CommonError::InvalidFillDeadline);
    }

    // Calculate exclusivity deadline if applicable.
    let mut exclusivity_deadline = exclusivity_parameter;
    if exclusivity_deadline > 0 {
        if exclusivity_deadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS {
            exclusivity_deadline += current_time;
        }

        // Ensure a valid exclusive relayer is provided.
        if exclusive_relayer == Pubkey::default() {
            return err!(CommonError::InvalidExclusiveRelayer);
        }
    }

    // Transfer tokens from the depositor to the vault.
    transfer_from(
        &ctx.accounts.depositor_token_account,
        &ctx.accounts.vault,
        input_amount,
        state,
        ctx.bumps.state,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
    )?;

    // Use the deposit ID or generate one based on the state's deposit count.
    let mut applied_deposit_id = deposit_id;
    if deposit_id == ZERO_DEPOSIT_ID {
        state.number_of_deposits += 1;
        applied_deposit_id[..4].copy_from_slice(&state.number_of_deposits.to_le_bytes());
    }

    emit_cpi!(V3FundsDeposited {
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

/// Deposits tokens with default deposit ID generation.
///
/// ### Parameters:
/// - `ctx`: The context for the deposit.
/// - `depositor`: The depositor's public key.
/// - `recipient`: The recipient's public key.
/// - `input_token`: The input token's public key.
/// - `output_token`: The output token's public key.
/// - `input_amount`: The amount of input tokens to deposit.
/// - `output_amount`: The amount of output tokens to deposit.
/// - `destination_chain_id`: The destination chain ID.
/// - `exclusive_relayer`: The exclusive relayer's public key.
/// - `quote_timestamp`: The timestamp when the quote was provided.
/// - `fill_deadline`: The deadline by which the deposit must be filled.
/// - `exclusivity_parameter`: The exclusivity parameter.
/// - `message`: The message to be attached to the deposit event.
pub fn deposit_v3(
    ctx: Context<DepositV3>,
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
    _deposit_v3(
        ctx,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        ZERO_DEPOSIT_ID, // Use ZERO_DEPOSIT_ID to generate deposit ID internally.
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
    )?;

    Ok(())
}

/// Deposits tokens with dynamically calculated current time for deadlines.
///
/// ### Parameters:
/// - `ctx`: The context for the deposit.
/// - `depositor`: The depositor's public key.
/// - `recipient`: The recipient's public key.
/// - `input_token`: The input token's public key.
/// - `output_token`: The output token's public key.
/// - `input_amount`: The amount of input tokens to deposit.
/// - `output_amount`: The amount of output tokens to deposit.
/// - `destination_chain_id`: The destination chain ID.
/// - `exclusive_relayer`: The exclusive relayer's public key.
/// - `fill_deadline_offset`: The offset for the fill deadline.
/// - `exclusivity_period`: The exclusivity period.
/// - `message`: The message to be attached to the deposit event.
pub fn deposit_v3_now(
    ctx: Context<DepositV3>,
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
    deposit_v3(
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

/// Unsafe deposit function using a manually calculated deposit ID.
///
/// ### Parameters:
/// - `ctx`: The context for the deposit.
/// - `depositor`: The depositor's public key.
/// - `recipient`: The recipient's public key.
/// - `input_token`: The input token's public key.
/// - `output_token`: The output token's public key.
/// - `input_amount`: The amount of input tokens to deposit.
/// - `output_amount`: The amount of output tokens to deposit.
/// - `destination_chain_id`: The destination chain ID.
/// - `exclusive_relayer`: The exclusive relayer's public key.
/// - `deposit_nonce`: The deposit nonce.
/// - `quote_timestamp`: The timestamp when the quote was provided.
/// - `fill_deadline`: The deadline by which the deposit must be filled.
/// - `exclusivity_parameter`: The exclusivity parameter.
/// - `message`: The message to be attached to the deposit event.
pub fn unsafe_deposit_v3(
    ctx: Context<DepositV3>,
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
    _deposit_v3(
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
