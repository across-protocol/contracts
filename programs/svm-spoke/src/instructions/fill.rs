use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    common::RelayData,
    constants::{DISCRIMINATOR_SIZE, FILL_STATUS_SEED},
    constraints::is_relay_hash_valid,
    error::{CommonError, SvmError},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    state::{FillRelayParams, FillStatus, FillStatusAccount, State},
    utils::{
        derive_seed_hash, get_current_time, hash_non_empty_message, invoke_handler, is_v5_message, transfer_from,
        FillSeedData,
    },
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

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// CHECK: PDA derived with seeds ["delegate", seed_hash]; used as a CPI signer.
    pub delegate: UncheckedAccount<'info>,

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
        seeds = [FILL_STATUS_SEED, relay_hash.as_ref()],
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

pub enum FillStatusMode<'a> {
    Legacy(&'a FillStatus),
    V5,
}

/// Executes the shared fill validation, replay/type resolution, and canonical event construction. Instruction
/// handlers remain responsible for their intentionally distinct funding, status-account creation, callback, and event
/// emission mechanics.
#[inline(never)]
pub fn _fill(
    state: &State,
    relay_data: &RelayData,
    repayment_chain_id: u64,
    repayment_address: Pubkey,
    filler: Pubkey,
    status: FillStatusMode<'_>,
    callback_enabled: bool,
) -> Result<FilledRelay> {
    require!(!state.paused_fills, CommonError::FillsArePaused);

    let current_time = get_current_time(state)?;
    if relay_data.exclusive_relayer != filler
        && relay_data.exclusivity_deadline >= current_time
        && relay_data.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }
    require!(relay_data.fill_deadline >= current_time, CommonError::ExpiredFillDeadline);

    let fill_type = match status {
        FillStatusMode::Legacy(status) => match status {
            FillStatus::Filled => return err!(CommonError::RelayFilled),
            FillStatus::RequestedSlowFill => FillType::ReplacedSlowFill,
            FillStatus::Unfilled => FillType::FastFill,
        },
        FillStatusMode::V5 => FillType::FastFill,
    };

    let message_hash = hash_non_empty_message(&relay_data.message);
    Ok(FilledRelay {
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
            updated_message_hash: if callback_enabled { message_hash } else { [0u8; 32] },
            updated_output_amount: relay_data.output_amount,
            fill_type,
        },
    })
}

pub fn fill_relay<'info>(
    ctx: Context<'_, '_, '_, 'info, FillRelay<'info>>,
    relay_hash: [u8; 32],
    relay_data: Option<RelayData>,
    repayment_chain_id: Option<u64>,
    repayment_address: Option<Pubkey>,
) -> Result<()> {
    // Fail fast before loading buffered params; `_fill` repeats the invariant for both entrypoints.
    require!(!ctx.accounts.state.paused_fills, CommonError::FillsArePaused);

    let FillRelayParams { relay_data, repayment_chain_id, repayment_address } =
        unwrap_fill_relay_params(relay_data, repayment_chain_id, repayment_address, &ctx.accounts.instruction_params);

    // V5 tagged deposits must be filled through new V5 entrypoints
    if is_v5_message(&relay_data.message) {
        return err!(CommonError::V5FillOnly);
    }

    let filler = ctx.accounts.signer.key();
    let event = _fill(
        &ctx.accounts.state,
        &relay_data,
        repayment_chain_id,
        repayment_address,
        filler,
        FillStatusMode::Legacy(&ctx.accounts.fill_status.status),
        true,
    )?;

    let seed_hash = derive_seed_hash(&(FillSeedData { relay_hash, repayment_chain_id, repayment_address }));
    transfer_from(
        &ctx.accounts.relayer_token_account,
        &ctx.accounts.recipient_token_account,
        relay_data.output_amount,
        &ctx.accounts.delegate,
        &ctx.accounts.mint,
        &ctx.accounts.token_program,
        seed_hash,
    )?;

    ctx.accounts.fill_status.status = FillStatus::Filled;
    ctx.accounts.fill_status.relayer = filler;
    ctx.accounts.fill_status.fill_deadline = relay_data.fill_deadline;

    if !relay_data.message.is_empty() {
        invoke_handler(ctx.accounts.signer.as_ref(), ctx.remaining_accounts, &relay_data.message)?;
    }

    emit_cpi!(event);

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

#[cfg(all(test, feature = "test"))]
mod tests {
    use super::*;

    fn state() -> State {
        State {
            paused_deposits: false,
            paused_fills: false,
            owner: Pubkey::new_unique(),
            seed: 0,
            number_of_deposits: 0,
            chain_id: 342_683_945_514_51,
            current_time: 100,
            remote_domain: 0,
            cross_domain_admin: Pubkey::new_unique(),
            root_bundle_id: 0,
            deposit_quote_time_buffer: 0,
            fill_deadline_buffer: 0,
        }
    }

    fn relay_data() -> RelayData {
        RelayData {
            depositor: Pubkey::new_unique(),
            recipient: Pubkey::new_unique(),
            exclusive_relayer: Pubkey::default(),
            input_token: Pubkey::new_unique(),
            output_token: Pubkey::new_unique(),
            input_amount: [1; 32],
            output_amount: 42,
            origin_chain_id: 1,
            deposit_id: [2; 32],
            fill_deadline: 101,
            exclusivity_deadline: 99,
            message: vec![3],
        }
    }

    fn assert_error_name<T>(result: Result<T>, expected: &str) {
        match result {
            Err(anchor_lang::error::Error::AnchorError(error)) => assert_eq!(error.error_name, expected),
            Err(_) => panic!("expected Anchor error"),
            Ok(_) => panic!("expected error"),
        }
    }

    #[test]
    fn shared_fill_core_preserves_entrypoint_event_semantics() {
        let state = state();
        let relay = relay_data();
        let filler = Pubkey::new_unique();
        let repayment_address = Pubkey::new_unique();
        let legacy =
            _fill(&state, &relay, 10, repayment_address, filler, FillStatusMode::Legacy(&FillStatus::Unfilled), true)
                .unwrap();
        let v5 = _fill(&state, &relay, 10, repayment_address, filler, FillStatusMode::V5, false).unwrap();

        assert_eq!(legacy.message_hash, v5.message_hash);
        assert_eq!(legacy.relayer, v5.relayer);
        assert_eq!(legacy.relay_execution_info.updated_recipient, v5.relay_execution_info.updated_recipient);
        assert_eq!(legacy.relay_execution_info.updated_output_amount, v5.relay_execution_info.updated_output_amount);
        assert_eq!(legacy.relay_execution_info.updated_message_hash, legacy.message_hash);
        assert_eq!(v5.relay_execution_info.updated_message_hash, [0; 32]);
        assert!(matches!(legacy.relay_execution_info.fill_type, FillType::FastFill));
        assert!(matches!(v5.relay_execution_info.fill_type, FillType::FastFill));
    }

    #[test]
    fn shared_fill_core_keeps_legacy_replay_resolution() {
        let state = state();
        let relay = relay_data();
        let filler = Pubkey::new_unique();
        let event = _fill(
            &state,
            &relay,
            10,
            Pubkey::new_unique(),
            filler,
            FillStatusMode::Legacy(&FillStatus::RequestedSlowFill),
            true,
        )
        .unwrap();
        assert!(matches!(event.relay_execution_info.fill_type, FillType::ReplacedSlowFill));

        assert_error_name(
            _fill(&state, &relay, 10, Pubkey::new_unique(), filler, FillStatusMode::Legacy(&FillStatus::Filled), true),
            "RelayFilled",
        );
    }

    #[test]
    fn shared_fill_core_applies_common_guards_to_both_modes() {
        let mut state = state();
        let mut relay = relay_data();
        let filler = Pubkey::new_unique();

        state.paused_fills = true;
        assert_error_name(
            _fill(&state, &relay, 10, Pubkey::new_unique(), filler, FillStatusMode::V5, false),
            "FillsArePaused",
        );
        state.paused_fills = false;

        relay.exclusive_relayer = Pubkey::new_unique();
        relay.exclusivity_deadline = state.current_time;
        assert_error_name(
            _fill(
                &state,
                &relay,
                10,
                Pubkey::new_unique(),
                filler,
                FillStatusMode::Legacy(&FillStatus::Unfilled),
                true,
            ),
            "NotExclusiveRelayer",
        );

        relay.exclusive_relayer = Pubkey::default();
        relay.fill_deadline = state.current_time - 1;
        assert_error_name(
            _fill(&state, &relay, 10, Pubkey::new_unique(), filler, FillStatusMode::V5, false),
            "ExpiredFillDeadline",
        );
    }
}

#[derive(Accounts)]
pub struct CloseFillPda<'info> {
    /// CHECK: The address constraint binds this non-signing account to the recorded rent recipient.
    #[account(mut, address = fill_status.relayer @ SvmError::NotRelayer)]
    pub signer: UncheckedAccount<'info>,

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
