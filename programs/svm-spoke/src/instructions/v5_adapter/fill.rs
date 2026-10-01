use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::{associated_token::get_associated_token_address_with_program_id, token_interface::TransferChecked};

use crate::{
    constants::{V5_FILL_DELEGATE, V5_MAGIC_PREFIX},
    error::{CommonError, V5Error},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    utils::{get_current_time, get_relay_hash, transfer_from, V5TransferDelegate},
    v5::{
        accounts::find_v5_account,
        codec::{decode_strict, GatewayContextV1, V5FillInput, V5FillJit},
        fill_status::{create_v5_fill_status_account, V5FillStatusPdas},
    },
};

use super::{
    token::{load_token_account, V5TokenAccounts},
    AdapterExecuteAcrossV5,
};

pub(super) fn execute_v5_fill<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: GatewayContextV1,
    fill_input: V5FillInput,
    jit_data: &[u8],
) -> Result<()> {
    // Fail fast before decoding fill JIT data.
    require!(!ctx.accounts.state.paused_fills, CommonError::FillsArePaused);

    let jit: V5FillJit = decode_strict(jit_data)?;
    let relay = &jit.relay_data;
    require!(
        relay.recipient == fill_input.recipient
            && relay.output_token == fill_input.output_token
            && relay.message.len() == 64
            && relay.message[..32] == V5_MAGIC_PREFIX
            && relay.message[32..] == ctx_values.step_id,
        V5Error::FillCommitmentMismatch
    );
    require!(relay.output_amount >= fill_input.min_output_amount, V5Error::FillOutputAmountTooLow);

    let message_hash = keccak::hash(&relay.message).to_bytes();
    let relay_hash = get_relay_hash(relay, ctx.accounts.state.chain_id, &message_hash);
    let accounts = V5FillAccounts::load(ctx.remaining_accounts, &fill_input, &ctx_values.submitter, &relay_hash)?;
    let current_time = get_current_time(&ctx.accounts.state)?;

    // Check if the exclusivity deadline has passed or if the caller is the exclusive relayer.
    if relay.exclusive_relayer != ctx_values.submitter
        && relay.exclusivity_deadline >= current_time
        && relay.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }

    // Check if the fill deadline has passed.
    if relay.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Account creation rejects existing program-owned state; V5 has no slow-fill lifecycle.
    let fill_status = create_v5_fill_status_account(
        &accounts.payer,
        &accounts.fill_status,
        &accounts.system_program,
        &accounts.fill_status_pdas,
    )?;

    // Self-transfers validate balance, frozen state, and authority without debiting funds or allowance.
    // The committed Gateway tape must enforce balance checks covering all fill obligations and consume the funds.
    transfer_from(
        accounts.transfer,
        accounts.token_program,
        relay.output_amount,
        accounts.mint_decimals,
        V5TransferDelegate::Fill,
    )?;

    // Update the fill status and rent-reclaim metadata; V5 stores its payer PDA as the rent recipient.
    fill_status.write_filled(relay.fill_deadline)?;

    emit_cpi!(FilledRelay {
        input_token: relay.input_token,
        output_token: relay.output_token,
        input_amount: relay.input_amount,
        output_amount: relay.output_amount,
        repayment_chain_id: jit.repayment_chain_id,
        origin_chain_id: relay.origin_chain_id,
        deposit_id: relay.deposit_id,
        fill_deadline: relay.fill_deadline,
        exclusivity_deadline: relay.exclusivity_deadline,
        exclusive_relayer: relay.exclusive_relayer,
        relayer: jit.repayment_address,
        depositor: relay.depositor,
        recipient: relay.recipient,
        message_hash,
        relay_execution_info: RelayExecutionEventInfo {
            updated_recipient: relay.recipient,
            updated_message_hash: [0; 32],
            updated_output_amount: relay.output_amount,
            fill_type: FillType::FastFill,
        },
    });
    Ok(())
}

struct V5FillAccounts<'a, 'info> {
    transfer: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    mint_decimals: u8,
    payer: AccountInfo<'info>,
    fill_status: AccountInfo<'info>,
    system_program: AccountInfo<'info>,
    fill_status_pdas: V5FillStatusPdas<'a>,
}

impl<'a, 'info> V5FillAccounts<'a, 'info> {
    fn load(
        remaining_accounts: &[AccountInfo<'info>],
        fill_input: &V5FillInput,
        submitter: &'a Pubkey,
        relay_hash: &'a [u8; 32],
    ) -> Result<Self> {
        let token_accounts = V5TokenAccounts::load(remaining_accounts, &fill_input.output_token)?;
        let recipient = get_associated_token_address_with_program_id(
            &fill_input.recipient,
            &fill_input.output_token,
            token_accounts.token_program.key,
        );
        let recipient_info = find_v5_account(remaining_accounts, &recipient, true)?;
        load_token_account(
            recipient_info,
            token_accounts.token_program.key,
            &fill_input.output_token,
            &fill_input.recipient,
        )?;

        let delegate = find_v5_account(remaining_accounts, &V5_FILL_DELEGATE, false)?;

        let fill_status_pdas = V5FillStatusPdas::derive(submitter, relay_hash);
        let payer_info = find_v5_account(remaining_accounts, &fill_status_pdas.payer(), true)?;
        let fill_status_info = find_v5_account(remaining_accounts, &fill_status_pdas.fill_status(), true)?;
        let system_program_info = find_v5_account(remaining_accounts, &anchor_lang::system_program::ID, false)?;

        Ok(Self {
            transfer: TransferChecked {
                from: token_accounts.gateway_vault,
                mint: token_accounts.mint,
                to: recipient_info.clone(),
                authority: delegate.clone(),
            },
            token_program: token_accounts.token_program,
            mint_decimals: token_accounts.mint_decimals,
            payer: payer_info.clone(),
            fill_status: fill_status_info.clone(),
            system_program: system_program_info.clone(),
            fill_status_pdas,
        })
    }
}
