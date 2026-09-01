use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_option::COption;
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_2022::spl_token_2022::{
        extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
        state::Mint as SplMint,
    },
    token_interface::{Mint, TokenAccount},
};

use crate::{
    constants::{GATEWAY_PROGRAM_ID, V5_FILL_DELEGATE_SEED, V5_MAGIC_PREFIX, V5_SOURCE_DELEGATE_SEED},
    error::{CommonError, V5Error},
    state::State,
    utils::{get_relay_hash, DelegatePda},
    v5::{
        decode_v5_adapter_input, decode_v5_deposit_jit, decode_v5_fill_jit, derive_fill_status,
        derive_gateway_vault_authority, derive_v5_deposit_id, derive_v5_fill_delegate, derive_v5_fill_payer,
        derive_v5_source_delegate, find_v5_account, require_gateway_dispatch_authority, require_v5_delegate_allowance,
        resolve_v5_deposit_modifications, resolve_v5_input_amount, AcrossDepositInput, V5AdapterMode, V5FillInput,
        V5GatewayContext,
    },
};

use super::{_deposit, _fill, DepositAccounts, DepositId, FillAccounts, FillExecution, FillStatusMode};

#[event_cpi]
#[derive(Accounts)]
pub struct AdapterExecuteAcrossV5<'info> {
    /// CHECK: Must be the live Gateway PDA for this program and must sign the CPI.
    pub dispatch_authority: UncheckedAccount<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn adapter_execute_across_v5<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: V5GatewayContext,
    input: Vec<u8>,
    jit_data: Vec<u8>,
) -> Result<()> {
    require_gateway_dispatch_authority(&ctx.accounts.dispatch_authority)?;
    match decode_v5_adapter_input(&input)?.mode {
        V5AdapterMode::Deposit(deposit) => execute_v5_deposit(ctx, ctx_values, deposit, &jit_data),
        V5AdapterMode::Fill(fill) => execute_v5_fill(ctx, ctx_values, fill, &jit_data),
    }
}

fn execute_v5_deposit<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: V5GatewayContext,
    deposit: AcrossDepositInput,
    jit_data: &[u8],
) -> Result<()> {
    require!(!ctx.accounts.state.paused_deposits, CommonError::DepositsArePaused);

    let jit = decode_v5_deposit_jit(&deposit, jit_data)?;
    let params = &deposit.deposit_params;
    let (output_amount, exclusive_relayer) = match jit {
        Some(jit) => resolve_v5_deposit_modifications(&deposit, &jit, &GATEWAY_PROGRAM_ID, &ctx_values.path_id)?,
        None => (params.output_amount, params.exclusive_relayer),
    };
    let (accounts, source) =
        load_v5_deposit_accounts(ctx.remaining_accounts, ctx.accounts.state.key(), params.input_token)?;
    let input_amount = resolve_v5_input_amount(deposit.input_amount_mode, params.input_amount, source.amount)?;
    // Match EVM transferFrom semantics: sufficient and max allowances are valid; the adapter pulls exactly
    // input_amount.
    require_v5_delegate_allowance(source.delegated_amount, input_amount)?;

    let mut message = Vec::with_capacity(64);
    message.extend_from_slice(&V5_MAGIC_PREFIX);
    message.extend_from_slice(&deposit.dst_step_id);
    let event = _deposit(
        accounts,
        params.depositor,
        params.recipient,
        params.input_token,
        params.output_token,
        input_amount,
        output_amount,
        params.destination_chain_id,
        exclusive_relayer,
        DepositId::Fixed {
            state: &ctx.accounts.state,
            value: derive_v5_deposit_id(
                &GATEWAY_PROGRAM_ID,
                &ctx_values.submitter,
                &ctx_values.path_id,
                &params.depositor,
                params.deposit_nonce,
            ),
        },
        params.quote_timestamp,
        params.fill_deadline,
        params.exclusivity_parameter,
        message,
        DelegatePda::FunctionSeed(V5_SOURCE_DELEGATE_SEED),
    )?;
    emit_cpi!(event);
    Ok(())
}

fn execute_v5_fill<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: V5GatewayContext,
    fill: V5FillInput,
    jit_data: &[u8],
) -> Result<()> {
    // Fail fast before decoding branch-specific JIT data; `_fill` repeats the invariant for both entrypoints.
    require!(!ctx.accounts.state.paused_fills, CommonError::FillsArePaused);

    let jit = decode_v5_fill_jit(jit_data)?;
    let relay = &jit.relay_data;
    require!(
        relay.recipient == fill.recipient
            && relay.output_token == fill.output_token
            && relay.message.len() == 64
            && relay.message[..32] == V5_MAGIC_PREFIX
            && relay.message[32..] == ctx_values.step_id,
        V5Error::FillCommitmentMismatch
    );
    require!(relay.output_amount >= fill.min_output_amount, V5Error::FillOutputAmountTooLow);

    let relay_hash = get_relay_hash(relay, ctx.accounts.state.chain_id);
    let accounts =
        load_v5_fill_accounts(ctx.remaining_accounts, &fill, relay.output_amount, &ctx_values.submitter, &relay_hash)?;
    let V5FillAccounts { fill: fill_accounts, payer, fill_status, system_program } = accounts;
    let event = _fill(
        fill_accounts,
        &ctx.accounts.state,
        relay,
        FillExecution::delivery_only(&fill.message),
        jit.repayment_chain_id,
        jit.repayment_address,
        ctx_values.submitter,
        FillStatusMode::V5 {
            payer: &payer,
            fill_status: &fill_status,
            system_program: &system_program,
            relay_hash: &relay_hash,
        },
        DelegatePda::FunctionSeed(V5_FILL_DELEGATE_SEED),
    )?;

    emit_cpi!(event);
    Ok(())
}

struct V5FillAccounts<'info> {
    fill: FillAccounts<'info>,
    payer: AccountInfo<'info>,
    fill_status: AccountInfo<'info>,
    system_program: AccountInfo<'info>,
}

fn load_v5_fill_accounts<'info>(
    remaining_accounts: &[AccountInfo<'info>],
    fill: &V5FillInput,
    output_amount: u64,
    submitter: &Pubkey,
    relay_hash: &[u8; 32],
) -> Result<V5FillAccounts<'info>> {
    let mint_info = find_v5_account(remaining_accounts, &fill.output_token, false)?;
    let token_program_id = *mint_info.owner;
    require!(
        token_program_id == anchor_spl::token::ID || token_program_id == anchor_spl::token_2022::ID,
        V5Error::InvalidTokenAccount
    );
    let token_program = find_v5_account(remaining_accounts, &token_program_id, false)?;
    require!(token_program.executable, V5Error::InvalidTokenAccount);
    reject_unsupported_mint_extensions(mint_info, &token_program_id)?;

    let (vault_authority, _) = derive_gateway_vault_authority();
    let gateway_vault =
        get_associated_token_address_with_program_id(&vault_authority, &fill.output_token, &token_program_id);
    let recipient =
        get_associated_token_address_with_program_id(&fill.recipient, &fill.output_token, &token_program_id);
    let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
    let recipient_info = find_v5_account(remaining_accounts, &recipient, true)?;
    let mint_decimals = load_mint(mint_info)?.decimals;
    let source = load_token_account(gateway_vault_info, &token_program_id, &fill.output_token, &vault_authority)?;
    load_token_account(recipient_info, &token_program_id, &fill.output_token, &fill.recipient)?;

    let (fill_delegate, _) = derive_v5_fill_delegate();
    let fill_delegate_info = if gateway_vault == recipient {
        require!(source.amount >= output_amount, V5Error::InsufficientVaultBalance);
        None
    } else {
        require!(source.delegate == COption::Some(fill_delegate), V5Error::InvalidTokenAccount);
        require_v5_delegate_allowance(source.delegated_amount, output_amount)?;
        Some(find_v5_account(remaining_accounts, &fill_delegate, false)?.clone())
    };

    let (payer, _) = derive_v5_fill_payer(submitter);
    let payer_info = find_v5_account(remaining_accounts, &payer, true)?;
    let (fill_status, _) = derive_fill_status(relay_hash);
    let fill_status_info = find_v5_account(remaining_accounts, &fill_status, true)?;
    let system_program_info = find_v5_account(remaining_accounts, &anchor_lang::system_program::ID, false)?;

    Ok(V5FillAccounts {
        fill: FillAccounts {
            from: gateway_vault_info.clone(),
            recipient: recipient_info.clone(),
            delegate: fill_delegate_info,
            mint: mint_info.clone(),
            token_program: token_program.clone(),
            mint_decimals,
        },
        payer: payer_info.clone(),
        fill_status: fill_status_info.clone(),
        system_program: system_program_info.clone(),
    })
}

fn load_v5_deposit_accounts<'info>(
    remaining_accounts: &[AccountInfo<'info>],
    state: Pubkey,
    input_token: Pubkey,
) -> Result<(DepositAccounts<'info>, TokenAccount)> {
    let mint_info = find_v5_account(remaining_accounts, &input_token, false)?;
    let token_program_id = *mint_info.owner;
    // Mirror Interface<TokenInterface>: accept only a supported executable token program.
    require!(
        token_program_id == anchor_spl::token::ID || token_program_id == anchor_spl::token_2022::ID,
        V5Error::InvalidTokenAccount
    );
    let token_program = find_v5_account(remaining_accounts, &token_program_id, false)?;
    reject_unsupported_mint_extensions(mint_info, &token_program_id)?;

    let (gateway_vault_authority, _) = derive_gateway_vault_authority();
    let gateway_vault =
        get_associated_token_address_with_program_id(&gateway_vault_authority, &input_token, &token_program_id);
    let spoke_vault = get_associated_token_address_with_program_id(&state, &input_token, &token_program_id);
    let (source_delegate, _) = derive_v5_source_delegate();
    let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
    let spoke_vault_info = find_v5_account(remaining_accounts, &spoke_vault, true)?;
    let source_delegate_info = find_v5_account(remaining_accounts, &source_delegate, false)?;

    // Together with the canonical addresses above, these checks mirror the corresponding static mint and
    // associated-token constraints.
    let mint = load_mint(mint_info)?;
    let source = load_token_account(gateway_vault_info, &token_program_id, &input_token, &gateway_vault_authority)?;
    load_token_account(spoke_vault_info, &token_program_id, &input_token, &state)?;
    require!(source.delegate == COption::Some(source_delegate), V5Error::InvalidTokenAccount);

    Ok((
        DepositAccounts {
            from: gateway_vault_info.clone(),
            vault: spoke_vault_info.clone(),
            delegate: source_delegate_info.clone(),
            mint: mint_info.clone(),
            token_program: token_program.clone(),
            mint_decimals: mint.decimals,
        },
        source,
    ))
}

fn load_mint(info: &AccountInfo) -> Result<Mint> {
    Mint::try_deserialize(&mut &info.try_borrow_data()?[..]).map_err(|_| error!(V5Error::InvalidTokenAccount))
}

fn load_token_account(
    info: &AccountInfo,
    token_program: &Pubkey,
    mint: &Pubkey,
    authority: &Pubkey,
) -> Result<TokenAccount> {
    require_keys_eq!(*info.owner, *token_program, V5Error::InvalidTokenAccount);
    let account = TokenAccount::try_deserialize(&mut &info.try_borrow_data()?[..])
        .map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    require_keys_eq!(account.mint, *mint, V5Error::InvalidTokenAccount);
    require_keys_eq!(account.owner, *authority, V5Error::InvalidTokenAccount);
    Ok(account)
}

fn reject_unsupported_mint_extensions(info: &AccountInfo, token_program: &Pubkey) -> Result<()> {
    if *token_program == anchor_spl::token::ID {
        return Ok(());
    }
    let data = info.try_borrow_data()?;
    let mint = StateWithExtensions::<SplMint>::unpack(&data).map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    let extensions = mint
        .get_extension_types()
        .map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    require!(extensions.iter().all(is_supported_v5_mint_extension), V5Error::UnsupportedTokenExtension);
    Ok(())
}

fn is_supported_v5_mint_extension(extension: &ExtensionType) -> bool {
    matches!(
        extension,
        ExtensionType::MintCloseAuthority
            | ExtensionType::MetadataPointer
            | ExtensionType::TokenMetadata
            | ExtensionType::GroupPointer
            | ExtensionType::TokenGroup
            | ExtensionType::GroupMemberPointer
            | ExtensionType::TokenGroupMember
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_2022_mint_extension_allowlist_is_fail_closed() {
        assert!(is_supported_v5_mint_extension(&ExtensionType::MetadataPointer));
        assert!(is_supported_v5_mint_extension(&ExtensionType::MintCloseAuthority));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::TransferFeeConfig));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::TransferHook));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::PermanentDelegate));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::DefaultAccountState));
    }
}
