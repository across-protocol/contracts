use anchor_lang::prelude::*;
use anchor_spl::{associated_token::get_associated_token_address_with_program_id, token_interface::TransferChecked};

use crate::{
    constants::{
        GATEWAY_PROGRAM_ID, MAX_EXCLUSIVITY_PERIOD_SECONDS, V5_DEPOSIT_DELEGATE,
        V5_MAGIC_PREFIX,
    },
    error::CommonError,
    event::FundsDeposited,
    utils::get_current_time,
    v5::{
        accounts::find_v5_account,
        codec::{decode_strict, resolve_v5_input_amount, AcrossDepositInput, GatewayContextV1},
        jit::{derive_v5_deposit_id, resolve_v5_deposit_modifications},
        transfer::{transfer_from, V5TransferDelegate},
    },
};

use super::{
    token::{load_token_account, V5TokenAccounts},
    AdapterExecuteAcrossV5,
};

pub(super) fn execute_v5_deposit<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: GatewayContextV1,
    deposit: AcrossDepositInput,
    jit_data: &[u8],
) -> Result<()> {
    require!(!ctx.accounts.state.paused_deposits, CommonError::DepositsArePaused);

    let params = &deposit.deposit_params;
    let (output_amount, exclusive_relayer) = if deposit.modification_rules.requires_jit() {
        let jit = decode_strict(jit_data)?;
        resolve_v5_deposit_modifications(&deposit, &jit, &GATEWAY_PROGRAM_ID, &ctx_values.path_id)?
    } else {
        (params.output_amount, params.exclusive_relayer)
    };
    let (accounts, gateway_vault_balance) =
        V5DepositAccounts::load(ctx.remaining_accounts, ctx.accounts.state.key(), params.input_token)?;
    let input_amount = resolve_v5_input_amount(deposit.input_amount_mode, params.input_amount, gateway_vault_balance)?;

    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;
    require!(params.output_token != Pubkey::default(), CommonError::InvalidOutputToken);
    require!(
        current_time.checked_sub(params.quote_timestamp).unwrap_or(u32::MAX) <= state.deposit_quote_time_buffer,
        CommonError::InvalidQuoteTimestamp
    );
    require!(params.fill_deadline <= current_time + state.fill_deadline_buffer, CommonError::InvalidFillDeadline);

    let mut exclusivity_deadline = params.exclusivity_parameter;
    if exclusivity_deadline > 0 {
        if exclusivity_deadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS {
            exclusivity_deadline += current_time;
        }
        require!(exclusive_relayer != Pubkey::default(), CommonError::InvalidExclusiveRelayer);
    }

    transfer_from(
        accounts.transfer,
        accounts.token_program,
        input_amount,
        accounts.mint_decimals,
        V5TransferDelegate::Deposit,
    )?;

    emit_cpi!(FundsDeposited {
        input_token: params.input_token,
        output_token: params.output_token,
        input_amount,
        output_amount,
        destination_chain_id: params.destination_chain_id,
        deposit_id: derive_v5_deposit_id(
            &GATEWAY_PROGRAM_ID,
            &ctx_values.submitter,
            &ctx_values.path_id,
            &params.depositor,
            params.deposit_nonce,
        ),
        quote_timestamp: params.quote_timestamp,
        fill_deadline: params.fill_deadline,
        exclusivity_deadline,
        depositor: params.depositor,
        recipient: params.recipient,
        exclusive_relayer,
        message: [V5_MAGIC_PREFIX, deposit.dst_step_id].concat(),
    });
    Ok(())
}

struct V5DepositAccounts<'info> {
    transfer: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    mint_decimals: u8,
}

impl<'info> V5DepositAccounts<'info> {
    fn load(remaining_accounts: &[AccountInfo<'info>], state: Pubkey, input_token: Pubkey) -> Result<(Self, u64)> {
        let token_accounts = V5TokenAccounts::load(remaining_accounts, &input_token)?;
        let spoke_vault =
            get_associated_token_address_with_program_id(&state, &input_token, token_accounts.token_program.key);
        let spoke_vault_info = find_v5_account(remaining_accounts, &spoke_vault, true)?;
        let deposit_delegate_info = find_v5_account(remaining_accounts, &V5_DEPOSIT_DELEGATE, false)?;

        load_token_account(spoke_vault_info, token_accounts.token_program.key, &input_token, &state)?;

        Ok((
            Self {
                transfer: TransferChecked {
                    from: token_accounts.gateway_vault,
                    mint: token_accounts.mint,
                    to: spoke_vault_info.clone(),
                    authority: deposit_delegate_info.clone(),
                },
                token_program: token_accounts.token_program,
                mint_decimals: token_accounts.mint_decimals,
            },
            token_accounts.gateway_vault_balance,
        ))
    }
}
