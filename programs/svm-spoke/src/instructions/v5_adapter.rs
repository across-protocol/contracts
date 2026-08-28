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
    constants::{GATEWAY_PROGRAM_ID, V5_MAGIC_PREFIX, V5_SOURCE_DELEGATE_SEED},
    error::{CommonError, V5Error},
    state::State,
    utils::DelegatePda,
    v5::{
        decode_v5_adapter_input, decode_v5_deposit_jit, derive_gateway_vault_authority, derive_v5_deposit_id,
        derive_v5_source_delegate, find_v5_account, require_gateway_dispatch_authority, require_v5_delegate_allowance,
        resolve_v5_deposit_modifications, resolve_v5_input_amount, AcrossDepositInput, V5AdapterMode, V5GatewayContext,
    },
};

use super::{DepositAccounts, DepositId, _deposit};

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
        V5AdapterMode::Fill(_) => err!(V5Error::UnsupportedMode),
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
