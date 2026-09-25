use anchor_lang::{prelude::*, solana_program::program_option::COption};
use anchor_spl::{associated_token::get_associated_token_address_with_program_id, token_interface::TransferChecked};

use crate::{
    constants::{GATEWAY_VAULT_AUTHORITY, V5_FILL_DELEGATE, V5_FILL_DELEGATE_SEED, V5_MAGIC_PREFIX},
    error::{CommonError, V5Error},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    instructions::{create_v5_fill_status_account, V5FillStatusPdas},
    utils::{get_current_time, get_relay_hash, hash_non_empty_message, transfer_from},
    v5::{
        codec::{decode_strict, GatewayContextV1, V5FillInput, V5FillJit},
        pda::find_v5_account,
    },
};

use super::{load_token_account, validate_v5_mint, AdapterExecuteAcrossV5};

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

    let relay_hash = get_relay_hash(relay, ctx.accounts.state.chain_id);
    let accounts = V5FillAccounts::load(
        ctx.remaining_accounts,
        &fill_input,
        relay.output_amount,
        &ctx_values.submitter,
        &relay_hash,
    )?;
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

    // Only authenticated in-place delivery skips the token transfer.
    match accounts.delivery {
        V5FillDelivery::Delegated(delegate) => transfer_from(
            TransferChecked { from: accounts.from, mint: accounts.mint, to: accounts.recipient, authority: delegate },
            accounts.token_program,
            relay.output_amount,
            accounts.mint_decimals,
            V5_FILL_DELEGATE_SEED,
        )?,
        V5FillDelivery::InPlace => {
            require_keys_eq!(accounts.from.key(), accounts.recipient.key(), V5Error::InvalidTokenAccount)
        }
    }

    // Update the fill status and rent-reclaim metadata; V5 stores its payer PDA as the rent recipient.
    fill_status.write_filled(relay.fill_deadline)?;

    // Empty message is not hashed and emits zeroed bytes32 for easier human observability.
    let message_hash = hash_non_empty_message(&relay.message);

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

enum V5FillDelivery<'info> {
    Delegated(AccountInfo<'info>),
    InPlace,
}

struct V5FillAccounts<'a, 'info> {
    from: AccountInfo<'info>,
    recipient: AccountInfo<'info>,
    delivery: V5FillDelivery<'info>,
    mint: AccountInfo<'info>,
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
        output_amount: u64,
        submitter: &'a Pubkey,
        relay_hash: &'a [u8; 32],
    ) -> Result<Self> {
        let mint_info = find_v5_account(remaining_accounts, &fill_input.output_token, false)?;
        let token_program_id = *mint_info.owner;
        require!(
            token_program_id == anchor_spl::token::ID || token_program_id == anchor_spl::token_2022::ID,
            V5Error::InvalidTokenAccount
        );
        let token_program = find_v5_account(remaining_accounts, &token_program_id, false)?;
        let mint_decimals = validate_v5_mint(mint_info, &token_program_id)?;

        let gateway_vault = get_associated_token_address_with_program_id(
            &GATEWAY_VAULT_AUTHORITY,
            &fill_input.output_token,
            &token_program_id,
        );
        let recipient = get_associated_token_address_with_program_id(
            &fill_input.recipient,
            &fill_input.output_token,
            &token_program_id,
        );
        let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
        let recipient_info = find_v5_account(remaining_accounts, &recipient, true)?;
        let source = load_token_account(
            gateway_vault_info,
            &token_program_id,
            &fill_input.output_token,
            &GATEWAY_VAULT_AUTHORITY,
        )?;
        load_token_account(recipient_info, &token_program_id, &fill_input.output_token, &fill_input.recipient)?;

        let delivery = if gateway_vault == recipient {
            // This check is not a debit. Builders must consume after one fill or enforce an aggregate floor covering
            // every in-place fill recorded before full-balance consumption; step-root reuse alone is valid.
            require!(source.amount >= output_amount, V5Error::InsufficientVaultBalance);
            V5FillDelivery::InPlace
        } else {
            require!(source.delegate == COption::Some(V5_FILL_DELEGATE), V5Error::InvalidTokenAccount);
            V5FillDelivery::Delegated(find_v5_account(remaining_accounts, &V5_FILL_DELEGATE, false)?.clone())
        };

        let fill_status_pdas = V5FillStatusPdas::derive(submitter, relay_hash);
        let payer_info = find_v5_account(remaining_accounts, &fill_status_pdas.payer(), true)?;
        let fill_status_info = find_v5_account(remaining_accounts, &fill_status_pdas.fill_status(), true)?;
        let system_program_info = find_v5_account(remaining_accounts, &anchor_lang::system_program::ID, false)?;

        Ok(Self {
            from: gateway_vault_info.clone(),
            recipient: recipient_info.clone(),
            delivery,
            mint: mint_info.clone(),
            token_program: token_program.clone(),
            mint_decimals,
            payer: payer_info.clone(),
            fill_status: fill_status_info.clone(),
            system_program: system_program_info.clone(),
            fill_status_pdas,
        })
    }
}
