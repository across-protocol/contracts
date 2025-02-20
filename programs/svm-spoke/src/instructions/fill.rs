use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    common::RelayData,
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::{CommonError, SvmError},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    state::{FillRelayParams, FillStatus, FillStatusAccount, State},
    utils::{get_current_time, hash_non_empty_message, invoke_handler, transfer_from},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: Option<RelayData>)]
pub struct FillRelay<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    // This is required as fallback when None instruction params are passed in arguments.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump, close = signer)]
    pub instruction_params: Option<Account<'info, FillRelayParams>>,

    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_fills @ CommonError::FillsArePaused
    )]
    pub state: Account<'info, State>,

    #[account(
        mint::token_program = token_program,
        address = relay_data
            .clone()
            .unwrap_or_else(|| instruction_params.as_ref().unwrap().relay_data.clone())
            .output_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        token::mint = mint,
        token::authority = signer,
        token::token_program = token_program
    )]
    pub relayer_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        associated_token::mint = mint,
        // Ensures tokens go to ATA owned by the recipient.
        associated_token::authority = relay_data
            .clone()
            .unwrap_or_else(|| instruction_params.as_ref().unwrap().relay_data.clone())
            .recipient,
        associated_token::token_program = token_program
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        constraint = is_relay_hash_valid(
            &relay_hash,
            &relay_data.clone().unwrap_or_else(|| instruction_params.as_ref().unwrap().relay_data.clone()),
            &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn fill_relay<'info>(
    ctx: Context<'_, '_, '_, 'info, FillRelay<'info>>,
    relay_data: Option<RelayData>,
    repayment_chain_id: Option<u64>,
    repayment_address: Option<Pubkey>,
) -> Result<()> {
    let FillRelayParams { relay_data, repayment_chain_id, repayment_address } =
        unwrap_fill_relay_params(relay_data, repayment_chain_id, repayment_address, &ctx.accounts.instruction_params);

    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;

    // Check if the exclusivity deadline has passed or if the caller is the exclusive relayer
    if relay_data.exclusive_relayer != ctx.accounts.signer.key()
        && relay_data.exclusivity_deadline >= current_time
        && relay_data.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }

    // Check if the fill deadline has passed
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Check the fill status and set the fill type
    let fill_status_account = &mut ctx.accounts.fill_status;
    let fill_type = match fill_status_account.status {
        FillStatus::Filled => {
            return err!(CommonError::RelayFilled);
        }
        FillStatus::RequestedSlowFill => FillType::ReplacedSlowFill,
        _ => FillType::FastFill,
    };

    // Relayer must have delegated output_amount to the state PDA
    transfer_from(
        &ctx.accounts.relayer_token_account,
        &ctx.accounts.recipient_token_account,
        relay_data.output_amount,
        state,
        ctx.bumps.state,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
    )?;

    // Update the fill status to Filled, set the relayer and fill deadline
    fill_status_account.status = FillStatus::Filled;
    fill_status_account.relayer = *ctx.accounts.signer.key;
    fill_status_account.fill_deadline = relay_data.fill_deadline;

    if !relay_data.message.is_empty() {
        invoke_handler(ctx.accounts.signer.as_ref(), ctx.remaining_accounts, &relay_data.message)?;
    }

    // Empty message is not hashed and emits zeroed bytes32 for easier human observability.
    let message_hash = hash_non_empty_message(&relay_data.message);

    emit_cpi!(FilledRelay {
        input_token: relay_data.input_token,
        output_token: relay_data.output_token,
        input_amount: relay_data.input_amount,
        output_amount: relay_data.output_amount,
        repayment_chain_id,
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        relayer: repayment_address,
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message_hash,
        relay_execution_info: RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message_hash: message_hash,
            updated_output_amount: relay_data.output_amount,
            fill_type,
        },
    });

    Ok(())
}

// Helper to unwrap optional instruction params with fallback loading from buffer account.
fn unwrap_fill_relay_params(
    relay_data: Option<RelayData>,
    repayment_chain_id: Option<u64>,
    repayment_address: Option<Pubkey>,
    account: &Option<Account<FillRelayParams>>,
) -> FillRelayParams {
    match (relay_data, repayment_chain_id, repayment_address) {
        (Some(relay_data), Some(repayment_chain_id), Some(repayment_address)) => {
            FillRelayParams { relay_data, repayment_chain_id, repayment_address }
        }
        _ => account
            .as_ref()
            .map(|account| FillRelayParams {
                relay_data: account.relay_data.clone(),
                repayment_chain_id: account.repayment_chain_id,
                repayment_address: account.repayment_address,
            })
            .unwrap(), // We do not expect this to panic here as missing instruction_params is unwrapped in context.
    }
}

#[derive(Accounts)]
pub struct CloseFillPda<'info> {
    #[account(mut, address = fill_status.relayer @ SvmError::NotRelayer)]
    pub signer: Signer<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    // No need to check seed derivation as this method only evaluates fill deadline that is recorded in this account.
    #[account(mut, close = signer)]
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
