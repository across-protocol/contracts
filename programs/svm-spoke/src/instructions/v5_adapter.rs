use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_2022::spl_token_2022::{
        extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
        state::Mint as SplMint,
    },
    token_interface::{Mint, TokenAccount},
};

use crate::{
    constants::{
        GATEWAY_PROGRAM_ID, GATEWAY_VAULT_AUTHORITY, V5_MAGIC_PREFIX, V5_SOURCE_DELEGATE, V5_SOURCE_DELEGATE_SEED,
    },
    error::{CommonError, V5Error},
    state::State,
    utils::DelegatePda,
    v5::{
        codec::{
            decode_strict, decode_v5_adapter_input, resolve_v5_input_amount, AcrossDepositInput, GatewayContextV1,
            V5AdapterInput,
        },
        jit::{derive_v5_deposit_id, resolve_v5_deposit_modifications},
        pda::{find_v5_account, require_gateway_dispatch_authority},
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
    ctx_values: GatewayContextV1,
    input: Vec<u8>,
    jit_data: Vec<u8>,
) -> Result<()> {
    require_gateway_dispatch_authority(&ctx.accounts.dispatch_authority)?;
    match decode_v5_adapter_input(&input)? {
        V5AdapterInput::DepositV1(deposit) => execute_v5_deposit(ctx, ctx_values, deposit, &jit_data),
        V5AdapterInput::FillV1(_) => err!(V5Error::UnsupportedMode),
    }
}

fn execute_v5_deposit<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: GatewayContextV1,
    deposit: AcrossDepositInput,
    jit_data: &[u8],
) -> Result<()> {
    require!(!ctx.accounts.state.paused_deposits, CommonError::DepositsArePaused);

    let params = &deposit.deposit_params;
    let (output_amount, exclusive_relayer) = if deposit.modification_rules.jit_enabled() {
        let jit = decode_strict(jit_data)?;
        resolve_v5_deposit_modifications(&deposit, &jit, &GATEWAY_PROGRAM_ID, &ctx_values.path_id)?
    } else {
        (params.output_amount, params.exclusive_relayer)
    };
    let (accounts, source) =
        load_v5_deposit_accounts(ctx.remaining_accounts, ctx.accounts.state.key(), params.input_token)?;
    let input_amount = resolve_v5_input_amount(deposit.input_amount_mode, params.input_amount, source.amount)?;

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
    require!(token_program.executable, V5Error::InvalidTokenAccount);
    reject_unsupported_mint_extensions(mint_info, &token_program_id)?;

    let gateway_vault =
        get_associated_token_address_with_program_id(&GATEWAY_VAULT_AUTHORITY, &input_token, &token_program_id);
    let spoke_vault = get_associated_token_address_with_program_id(&state, &input_token, &token_program_id);
    let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
    let spoke_vault_info = find_v5_account(remaining_accounts, &spoke_vault, true)?;
    let source_delegate_info = find_v5_account(remaining_accounts, &V5_SOURCE_DELEGATE, false)?;

    // Together with the canonical addresses above, these checks mirror the corresponding static mint and
    // associated-token constraints. Delegate authorization and allowance are enforced by transfer_checked.
    let mint = load_mint(mint_info, &token_program_id)?;
    let source = load_token_account(gateway_vault_info, &token_program_id, &input_token, &GATEWAY_VAULT_AUTHORITY)?;
    load_token_account(spoke_vault_info, &token_program_id, &input_token, &state)?;

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

fn load_mint(info: &AccountInfo, token_program: &Pubkey) -> Result<Mint> {
    require_keys_eq!(*info.owner, *token_program, V5Error::InvalidTokenAccount);
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
    require!(
        !extensions.contains(&ExtensionType::TransferFeeConfig) && !extensions.contains(&ExtensionType::TransferHook),
        V5Error::UnsupportedTokenExtension
    );
    Ok(())
}
