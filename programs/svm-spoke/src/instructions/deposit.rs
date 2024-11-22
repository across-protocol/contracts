use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    constants::MAX_EXCLUSIVITY_PERIOD_SECONDS,
    error::{CommonError, SvmError},
    event::V3FundsDeposited,
    get_current_time,
    state::{Route, State},
    utils::transfer_from,
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
        seeds = [b"route", input_token.as_ref(), state.key().as_ref(), destination_chain_id.to_le_bytes().as_ref()],
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
        associated_token::authority = state,
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

    if current_time.checked_sub(quote_timestamp).unwrap_or(u32::MAX) > state.deposit_quote_time_buffer {
        return err!(CommonError::InvalidQuoteTimestamp);
    }

    if fill_deadline < current_time || fill_deadline > current_time + state.fill_deadline_buffer {
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

    // Depositor must have delegated input_amount to the state PDA.
    transfer_from(
        &ctx.accounts.depositor_token_account,
        &ctx.accounts.vault,
        input_amount,
        state,
        ctx.bumps.state,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
    )?;

    let mut applied_deposit_id = deposit_id;
    if deposit_id.iter().all(|&x| x == 0) {
        state.number_of_deposits += 1;
        let mut deposit_id_bytes = [0u8; 32];
        deposit_id_bytes[..4].copy_from_slice(&state.number_of_deposits.to_le_bytes());
        applied_deposit_id = deposit_id_bytes;
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
        [0u8; 32], // deposit_id of informs internal function to use state.number_of_deposits as id.
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
    )?;

    Ok(())
}

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
    // Call the existing _deposit_v3 function
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

// Define a dummy context struct so we can export this as a view function in lib.
#[derive(Accounts)]
pub struct Null {}
pub fn get_unsafe_deposit_id(msg_sender: Pubkey, depositor: Pubkey, deposit_nonce: u64) -> [u8; 32] {
    let mut data = Vec::new();
    data.extend_from_slice(&msg_sender.to_bytes());
    data.extend_from_slice(&depositor.to_bytes());
    data.extend_from_slice(&deposit_nonce.to_le_bytes());

    keccak::hash(&data).0
}
