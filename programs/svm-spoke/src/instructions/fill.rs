use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    common::RelayData,
    constants::{DISCRIMINATOR_SIZE, FILL_STATUS_SEED},
    constraints::is_relay_hash_valid,
    error::{CommonError, SvmError, V5Error},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    state::{FillRelayParams, FillStatus, FillStatusAccount, State},
    utils::{
        derive_seed_hash, get_current_time, hash_non_empty_message, invoke_handler, is_v5_message,
        transfer_from_with_delegate, DelegatePda, FillSeedData,
    },
};

use super::create_v5_fill_status_account;

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

pub enum FillStatusMode<'a, 'info> {
    Legacy(&'a mut FillStatusAccount),
    V5 {
        payer: &'a AccountInfo<'info>,
        fill_status: &'a AccountInfo<'info>,
        system_program: &'a AccountInfo<'info>,
        relay_hash: &'a [u8; 32],
    },
}

enum FillStatusStorage<'a, 'info> {
    Legacy(&'a mut FillStatusAccount),
    V5(&'a AccountInfo<'info>),
}

impl FillStatusStorage<'_, '_> {
    fn write_filled(self, relayer: Pubkey, fill_deadline: u32) -> Result<()> {
        let filled = FillStatusAccount { status: FillStatus::Filled, relayer, fill_deadline };
        match self {
            Self::Legacy(fill_status) => {
                *fill_status = filled;
                Ok(())
            }
            Self::V5(fill_status) => filled.try_serialize(&mut &mut fill_status.try_borrow_mut_data()?[..]),
        }
    }
}

pub struct FillAccounts<'info> {
    pub from: AccountInfo<'info>,
    pub recipient: AccountInfo<'info>,
    /// `None` represents an authenticated in-place delivery that requires no token transfer.
    pub delegate: Option<AccountInfo<'info>>,
    pub mint: AccountInfo<'info>,
    pub token_program: AccountInfo<'info>,
    pub mint_decimals: u8,
}

impl<'info> From<&FillRelay<'info>> for FillAccounts<'info> {
    fn from(accounts: &FillRelay<'info>) -> Self {
        Self {
            from: accounts.relayer_token_account.to_account_info(),
            recipient: accounts.recipient_token_account.to_account_info(),
            delegate: Some(accounts.delegate.to_account_info()),
            mint: accounts.mint.to_account_info(),
            token_program: accounts.token_program.to_account_info(),
            mint_decimals: accounts.mint.decimals,
        }
    }
}

/// Executes shared fill validation, status transition, and token delivery, then constructs the canonical event.
/// Instruction handlers retain only branch-specific account loading, callbacks, and event emission.
// Preserve a separate SBF frame; inlining event construction can push stack-heavy fill handlers past the 4 KiB limit.
#[inline(never)]
pub fn _fill(
    accounts: FillAccounts<'_>,
    state: &State,
    relay_data: &RelayData,
    repayment_chain_id: u64,
    repayment_address: Pubkey,
    filler: Pubkey,
    status: FillStatusMode<'_, '_>,
    delegate_pda: DelegatePda,
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

    let (fill_status, fill_type, callback_enabled, status_relayer) = match status {
        FillStatusMode::Legacy(fill_status) => {
            let fill_type = match fill_status.status {
                FillStatus::Filled => return err!(CommonError::RelayFilled),
                FillStatus::RequestedSlowFill => FillType::ReplacedSlowFill,
                FillStatus::Unfilled => FillType::FastFill,
            };
            (FillStatusStorage::Legacy(fill_status), fill_type, true, filler)
        }
        FillStatusMode::V5 { payer, fill_status, system_program, relay_hash } => {
            let relayer = create_v5_fill_status_account(payer, fill_status, system_program, &filler, relay_hash)?;
            (FillStatusStorage::V5(fill_status), FillType::FastFill, false, relayer)
        }
    };
    // V5 reserves the relayer slot for its payer PDA so expiry reclaim restores the correct rent float.
    fill_status.write_filled(status_relayer, relay_data.fill_deadline)?;

    let message_hash = hash_non_empty_message(&relay_data.message);
    if let Some(delegate) = accounts.delegate {
        transfer_from_with_delegate(
            TransferChecked { from: accounts.from, mint: accounts.mint, to: accounts.recipient, authority: delegate },
            accounts.token_program,
            relay_data.output_amount,
            accounts.mint_decimals,
            delegate_pda,
        )?;
    } else {
        require_keys_eq!(accounts.from.key(), accounts.recipient.key(), V5Error::InvalidTokenAccount);
    }

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
    let seed_hash = derive_seed_hash(&(FillSeedData { relay_hash, repayment_chain_id, repayment_address }));
    let accounts = FillAccounts::from(&*ctx.accounts);
    let event = _fill(
        accounts,
        &ctx.accounts.state,
        &relay_data,
        repayment_chain_id,
        repayment_address,
        filler,
        FillStatusMode::Legacy(&mut ctx.accounts.fill_status),
        DelegatePda::UniqueHash(seed_hash),
    )?;

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

    fn account_info() -> AccountInfo<'static> {
        AccountInfo::new(
            Box::leak(Box::new(Pubkey::new_unique())),
            false,
            false,
            Box::leak(Box::new(0)),
            Box::leak(Vec::new().into_boxed_slice()),
            Box::leak(Box::new(Pubkey::new_unique())),
            false,
            0,
        )
    }

    fn in_place_fill_accounts() -> FillAccounts<'static> {
        let account = account_info();
        FillAccounts {
            from: account.clone(),
            recipient: account.clone(),
            delegate: None,
            mint: account.clone(),
            token_program: account,
            mint_decimals: 0,
        }
    }

    fn fill_without_transfer(
        state: &State,
        relay_data: &RelayData,
        repayment_chain_id: u64,
        repayment_address: Pubkey,
        filler: Pubkey,
        fill_status: &mut FillStatusAccount,
    ) -> Result<FilledRelay> {
        _fill(
            in_place_fill_accounts(),
            state,
            relay_data,
            repayment_chain_id,
            repayment_address,
            filler,
            FillStatusMode::Legacy(fill_status),
            DelegatePda::FunctionSeed(b"unused"),
        )
    }

    fn fill_status(status: FillStatus) -> FillStatusAccount {
        FillStatusAccount { status, relayer: Pubkey::default(), fill_deadline: 0 }
    }

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
    fn shared_fill_core_constructs_event_and_updates_status() {
        let state = state();
        let relay = relay_data();
        let filler = Pubkey::new_unique();
        let repayment_address = Pubkey::new_unique();
        let mut status = fill_status(FillStatus::Unfilled);
        let event = fill_without_transfer(&state, &relay, 10, repayment_address, filler, &mut status).unwrap();

        assert_eq!(event.relayer, repayment_address);
        assert_eq!(event.relay_execution_info.updated_recipient, relay.recipient);
        assert_eq!(event.relay_execution_info.updated_output_amount, relay.output_amount);
        assert_eq!(event.relay_execution_info.updated_message_hash, event.message_hash);
        assert!(matches!(event.relay_execution_info.fill_type, FillType::FastFill));
        assert!(matches!(status.status, FillStatus::Filled));
        assert_eq!(status.relayer, filler);
        assert_eq!(status.fill_deadline, relay.fill_deadline);
    }

    #[test]
    fn shared_fill_core_keeps_legacy_replay_resolution() {
        let state = state();
        let relay = relay_data();
        let filler = Pubkey::new_unique();
        let mut requested = fill_status(FillStatus::RequestedSlowFill);
        let event = fill_without_transfer(&state, &relay, 10, Pubkey::new_unique(), filler, &mut requested).unwrap();
        assert!(matches!(event.relay_execution_info.fill_type, FillType::ReplacedSlowFill));

        let mut filled = fill_status(FillStatus::Filled);
        assert_error_name(
            fill_without_transfer(&state, &relay, 10, Pubkey::new_unique(), filler, &mut filled),
            "RelayFilled",
        );
    }

    #[test]
    fn shared_fill_core_applies_common_guards_before_status_transition() {
        let mut state = state();
        let mut relay = relay_data();
        let filler = Pubkey::new_unique();
        let mut status = fill_status(FillStatus::Unfilled);

        state.paused_fills = true;
        assert_error_name(
            fill_without_transfer(&state, &relay, 10, Pubkey::new_unique(), filler, &mut status),
            "FillsArePaused",
        );
        state.paused_fills = false;

        relay.exclusive_relayer = Pubkey::new_unique();
        relay.exclusivity_deadline = state.current_time;
        assert_error_name(
            fill_without_transfer(&state, &relay, 10, Pubkey::new_unique(), filler, &mut status),
            "NotExclusiveRelayer",
        );

        relay.exclusive_relayer = Pubkey::default();
        relay.fill_deadline = state.current_time - 1;
        assert_error_name(
            fill_without_transfer(&state, &relay, 10, Pubkey::new_unique(), filler, &mut status),
            "ExpiredFillDeadline",
        );
        assert!(matches!(status.status, FillStatus::Unfilled));
    }

    #[test]
    fn shared_fill_core_only_skips_authenticated_in_place_delivery() {
        let mut accounts = in_place_fill_accounts();
        accounts.recipient = account_info();
        let mut status = fill_status(FillStatus::Unfilled);
        assert_error_name(
            _fill(
                accounts,
                &state(),
                &relay_data(),
                10,
                Pubkey::new_unique(),
                Pubkey::new_unique(),
                FillStatusMode::Legacy(&mut status),
                DelegatePda::FunctionSeed(b"unused"),
            ),
            "InvalidTokenAccount",
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
