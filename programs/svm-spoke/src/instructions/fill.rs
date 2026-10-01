use anchor_lang::prelude::*;
use anchor_spl::token_interface::TransferChecked;

use crate::{
    common::RelayData,
    error::{CommonError, SvmError, V5Error},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    state::{FillStatusAccount, State},
    utils::{get_current_time, hash_non_empty_message, transfer_from},
};

use super::{create_v5_fill_status_account, V5FillStatusPdas};

pub struct FillStatusInput<'a, 'info> {
    pub payer: &'a AccountInfo<'info>,
    pub fill_status: &'a AccountInfo<'info>,
    pub system_program: &'a AccountInfo<'info>,
    pub pdas: &'a V5FillStatusPdas<'a>,
}

pub enum FillDelivery<'info> {
    Delegated(AccountInfo<'info>),
    /// Tokens are already in the recipient account; `_fill` verifies the source and recipient match.
    InPlace,
}

pub struct FillAccounts<'info> {
    pub from: AccountInfo<'info>,
    pub recipient: AccountInfo<'info>,
    pub delivery: FillDelivery<'info>,
    pub mint: AccountInfo<'info>,
    pub token_program: AccountInfo<'info>,
    pub mint_decimals: u8,
}

/// Validates a V5 fill, delivers tokens, records its status, and constructs the event.
/// The adapter handles account loading, witness validation, and event emission.
// Preserve a separate SBF frame; inlining event construction can push stack-heavy fill handlers past the 4 KiB limit.
#[inline(never)]
pub fn _fill(
    accounts: FillAccounts<'_>,
    state: &State,
    relay_data: &RelayData,
    updated_message: &[u8],
    repayment_chain_id: u64,
    repayment_address: Pubkey,
    submitter: Pubkey,
    fill_status_input: FillStatusInput<'_, '_>,
    delegate_seed: &[u8],
) -> Result<FilledRelay> {
    require!(!state.paused_fills, CommonError::FillsArePaused);

    let current_time = get_current_time(state)?;

    // Check if the exclusivity deadline has passed or if the caller is the exclusive relayer.
    if relay_data.exclusive_relayer != submitter
        && relay_data.exclusivity_deadline >= current_time
        && relay_data.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }

    // Check if the fill deadline has passed.
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Account creation rejects existing program-owned state; V5 has no slow-fill lifecycle.
    let FillStatusInput { payer, fill_status, system_program, pdas } = fill_status_input;
    let fill_status = create_v5_fill_status_account(payer, fill_status, system_program, pdas)?;

    // Enforce the shared contract for explicitly selected in-place delivery.
    match accounts.delivery {
        FillDelivery::Delegated(delegate) => transfer_from(
            TransferChecked { from: accounts.from, mint: accounts.mint, to: accounts.recipient, authority: delegate },
            accounts.token_program,
            relay_data.output_amount,
            accounts.mint_decimals,
            delegate_seed,
        )?,
        FillDelivery::InPlace => {
            require_keys_eq!(accounts.from.key(), accounts.recipient.key(), V5Error::InvalidTokenAccount)
        }
    }

    // Update the fill status and rent-reclaim metadata; V5 stores its payer PDA as the rent recipient.
    fill_status.write_filled(relay_data.fill_deadline)?;

    // Empty message is not hashed and emits zeroed bytes32 for easier human observability.
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
            updated_message_hash: hash_non_empty_message(updated_message),
            updated_output_amount: relay_data.output_amount,
            fill_type: FillType::FastFill,
        },
    })
}

#[derive(Accounts)]
pub struct CloseFillPda<'info> {
    /// CHECK: The address constraint binds this account to the recorded rent recipient; no signature is required.
    /// The name `signer` is retained for client/IDL compatibility only. For V5 fills, supply the submitter's
    /// `["v5_fill_payer", submitter]` PDA recorded in `fill_status.relayer`; legacy fills retain the relayer address.
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
