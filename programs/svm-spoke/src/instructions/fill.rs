use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    common::V3RelayData,
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::{CommonError, SvmError},
    event::{FillType, FilledV3Relay, V3RelayExecutionEventInfo},
    state::{FillStatus, FillStatusAccount, State},
    utils::{get_current_time, hash_non_empty_message, invoke_handler, transfer_from},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct FillV3Relay<'info> {
    /// The signer who initiates the relay fill. Must match constraints in the logic.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// State account containing global configuration and paused state for fills.
    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_fills @ CommonError::FillsArePaused
    )]
    pub state: Account<'info, State>,

    /// The mint of the output token, validated against the relay data.
    #[account(
        mint::token_program = token_program,
        address = relay_data.output_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    /// Token account belonging to the relayer. This account must be mutable.
    #[account(
        mut,
        token::mint = mint,
        token::authority = signer,
        token::token_program = token_program
    )]
    pub relayer_token_account: InterfaceAccount<'info, TokenAccount>,

    /// Associated token account for the recipient. Tokens are transferred here.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = relay_data.recipient, // Ensures tokens go to ATA owned by the recipient.
        associated_token::token_program = token_program
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    /// PDA storing the current status of the relay fill. Initialized if needed.
    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    /// Interface to the token program, used for token transfers and account validation.
    pub token_program: Interface<'info, TokenInterface>,

    /// Associated token program, required to handle ATAs.
    pub associated_token_program: Program<'info, AssociatedToken>,

    /// System program, required for account initialization and rent payments.
    pub system_program: Program<'info, System>,
}

/// Handles the relay-filling logic.
///
/// Parameters:
/// - `ctx`: The context for the fill.
/// - `relay_data`: The relay data.
/// - `repayment_chain_id`: The chain ID of the repayment.
/// - `repayment_address`: The address of the repayment.
pub fn fill_v3_relay<'info>(
    ctx: Context<'_, '_, '_, 'info, FillV3Relay<'info>>,
    relay_data: V3RelayData,
    repayment_chain_id: u64,
    repayment_address: Pubkey,
) -> Result<()> {
    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;

    // Check if the caller is authorized to fill as the exclusive relayer.
    // If the exclusivity deadline hasn't passed, only the exclusive relayer can call this function.
    if relay_data.exclusive_relayer != ctx.accounts.signer.key()
        && relay_data.exclusivity_deadline >= current_time
        && relay_data.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }

    // Ensure that the fill deadline has not passed.
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Check the fill status and set the fill type.
    let fill_status_account = &mut ctx.accounts.fill_status;
    let fill_type = match fill_status_account.status {
        FillStatus::Filled => {
            return err!(CommonError::RelayFilled);
        }
        FillStatus::RequestedSlowFill => FillType::ReplacedSlowFill,
        _ => FillType::FastFill,
    };

    // Perform token transfer if the relayer and recipient accounts differ.
    if ctx.accounts.relayer_token_account.key() != ctx.accounts.recipient_token_account.key() {
        // Relayer must have delegated `output_amount` to the state PDA (if not self-relaying).
        transfer_from(
            &ctx.accounts.relayer_token_account,
            &ctx.accounts.recipient_token_account,
            relay_data.output_amount,
            state,
            ctx.bumps.state,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
        )?;
    }

    // Update the fill status to `Filled` and record the relayer.
    fill_status_account.status = FillStatus::Filled;
    fill_status_account.relayer = *ctx.accounts.signer.key;

    // Invoke handler if a non-empty message exists.
    if relay_data.message.len() > 0 {
        invoke_handler(
            ctx.accounts.signer.as_ref(),
            ctx.remaining_accounts,
            &relay_data.message,
        )?;
    }

    // Empty message is not hashed and emits zeroed bytes32 for easier human observability.
    let message_hash = hash_non_empty_message(&relay_data.message);

    // Emit a `FilledV3Relay` event containing details about the relay fill.
    emit_cpi!(FilledV3Relay {
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
        relay_execution_info: V3RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message_hash: message_hash,
            updated_output_amount: relay_data.output_amount,
            fill_type,
        },
    });

    Ok(())
}

#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct CloseFillPda<'info> {
    /// The relayer who initiated the relay fill. Must match the stored relayer in `fill_status`.
    #[account(mut, address = fill_status.relayer @ SvmError::NotRelayer)]
    pub signer: Signer<'info>,

    /// State account containing global configuration.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// PDA storing the relay fill status. Closed upon successful execution.
    #[account(
        mut,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        close = signer,
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,
}

/// Closes the PDA associated with a relay fill.
///
/// Parameters:
/// - `ctx`: The context for the close.
/// - `relay_data`: The relay data.
pub fn close_fill_pda(ctx: Context<CloseFillPda>, relay_data: V3RelayData) -> Result<()> {
    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;

    // Ensure that the current time exceeds the fill deadline.
    // Closing the PDA is restricted to avoid premature closure.
    if current_time <= relay_data.fill_deadline {
        return err!(SvmError::CanOnlyCloseFillStatusPdaIfFillDeadlinePassed);
    }

    Ok(())
}
