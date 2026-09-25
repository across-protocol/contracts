use anchor_lang::{prelude::*, solana_program::program_option::COption};
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_interface::{TokenAccount, TransferChecked},
};

use crate::{
    constants::{
        GATEWAY_PROGRAM_ID, GATEWAY_VAULT_AUTHORITY, MAX_EXCLUSIVITY_PERIOD_SECONDS, V5_DEPOSIT_DELEGATE,
        V5_DEPOSIT_DELEGATE_SEED, V5_MAGIC_PREFIX,
    },
    error::{CommonError, V5Error},
    event::FundsDeposited,
    utils::{get_current_time, transfer_from},
    v5::{
        accounts::find_v5_account,
        codec::{decode_strict, resolve_v5_input_amount, AcrossDepositInput, GatewayContextV1},
        jit::{derive_v5_deposit_id, resolve_v5_deposit_modifications},
    },
};

use super::{
    token::{load_token_account, validate_v5_mint},
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
    let (accounts, source) =
        V5DepositAccounts::load(ctx.remaining_accounts, ctx.accounts.state.key(), params.input_token)?;
    let input_amount = resolve_v5_input_amount(deposit.input_amount_mode, params.input_amount, source.amount)?;

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
        V5_DEPOSIT_DELEGATE_SEED,
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
    fn load(
        remaining_accounts: &[AccountInfo<'info>],
        state: Pubkey,
        input_token: Pubkey,
    ) -> Result<(Self, TokenAccount)> {
        let mint_info = find_v5_account(remaining_accounts, &input_token, false)?;
        let token_program_id = *mint_info.owner;
        // Mirror Interface<TokenInterface>: accept only a supported executable token program.
        require!(
            token_program_id == anchor_spl::token::ID || token_program_id == anchor_spl::token_2022::ID,
            V5Error::InvalidTokenAccount
        );
        let token_program = find_v5_account(remaining_accounts, &token_program_id, false)?;
        let mint_decimals = validate_v5_mint(mint_info, &token_program_id)?;

        let gateway_vault =
            get_associated_token_address_with_program_id(&GATEWAY_VAULT_AUTHORITY, &input_token, &token_program_id);
        let spoke_vault = get_associated_token_address_with_program_id(&state, &input_token, &token_program_id);
        let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
        let spoke_vault_info = find_v5_account(remaining_accounts, &spoke_vault, true)?;
        let deposit_delegate_info = find_v5_account(remaining_accounts, &V5_DEPOSIT_DELEGATE, false)?;

        // Canonical ATA addresses plus these owner, mint, and authority checks mirror the static associated-token
        // constraints.
        let source = load_token_account(gateway_vault_info, &token_program_id, &input_token, &GATEWAY_VAULT_AUTHORITY)?;
        load_token_account(spoke_vault_info, &token_program_id, &input_token, &state)?;
        require!(source.delegate == COption::Some(V5_DEPOSIT_DELEGATE), V5Error::InvalidTokenAccount);

        Ok((
            Self {
                transfer: TransferChecked {
                    from: gateway_vault_info.clone(),
                    mint: mint_info.clone(),
                    to: spoke_vault_info.clone(),
                    authority: deposit_delegate_info.clone(),
                },
                token_program: token_program.clone(),
                mint_decimals,
            },
            source,
        ))
    }
}
