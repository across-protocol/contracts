// Note: The `svm-spoke` does not support `speedUpDeposit` and `fillRelayWithUpdatedDeposit` due to cryptographic
// incompatibilities between Solana (Ed25519) and Ethereum (ECDSA secp256k1). Specifically, Solana wallets cannot
// generate ECDSA signatures required for Ethereum verification. As a result, speed-up functionality on Solana is not
// implemented. For more details, refer to the documentation: https://docs.across.to

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    constants::{MAX_EXCLUSIVITY_PERIOD_SECONDS, ZERO_DEPOSIT_ID},
    error::{CommonError, SvmError},
    event::FundsDeposited,
    state::State,
    utils::{
        derive_seed_hash, get_current_time, get_unsafe_deposit_id, transfer_from, DepositNowSeedData, DepositSeedData,
    },
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(depositor: Pubkey, recipient: Pubkey, input_token: Pubkey)]
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

    /// CHECK: PDA derived with seeds ["delegate", seed_hash]; used as a CPI signer.
    pub delegate: UncheckedAccount<'info>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = depositor,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = signer,
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

    pub associated_token_program: Program<'info, AssociatedToken>,

    pub system_program: Program<'info, System>,
}

pub fn _deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_id: [u8; 32],
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
    delegate_seed_hash: [u8; 32],
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let current_time = get_current_time(state)?;

    if output_token == Pubkey::default() {
        return err!(CommonError::InvalidOutputToken);
    }

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

    // Depositor must have delegated input_amount to the delegate PDA
    transfer_from(
        &ctx.accounts.depositor_token_account,
        &ctx.accounts.vault,
        input_amount,
        &ctx.accounts.delegate,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
        delegate_seed_hash,
    )?;

    let mut applied_deposit_id = deposit_id;
    // If the passed in deposit_id is all zeros, then we use the state's number of deposits as deposit_id.
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
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    let seed_hash = derive_seed_hash(
        &(DepositSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            quote_timestamp,
            fill_deadline,
            exclusivity_parameter,
            message: &message,
        }),
    );
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
        seed_hash,
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
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    fill_deadline_offset: u32,
    exclusivity_period: u32,
    message: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let current_time = get_current_time(state)?;
    let seed_hash = derive_seed_hash(
        &(DepositNowSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            fill_deadline_offset,
            exclusivity_period,
            message: &message,
        }),
    );
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
        current_time,
        current_time + fill_deadline_offset,
        exclusivity_period,
        message,
        seed_hash,
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
    output_amount: [u8; 32],
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
    let seed_hash = derive_seed_hash(
        &(DepositSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            quote_timestamp,
            fill_deadline,
            exclusivity_parameter,
            message: &message,
        }),
    );
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
        seed_hash,
    )?;

    Ok(())
}
