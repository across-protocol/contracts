use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_option::COption;
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_2022::spl_token_2022::{
        extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
        state::Mint as SplMint,
    },
    token_interface::{TokenAccount, TransferChecked},
};

use crate::{
    constants::{
        GATEWAY_PROGRAM_ID, GATEWAY_VAULT_AUTHORITY, MAX_EXCLUSIVITY_PERIOD_SECONDS, V5_FILL_DELEGATE,
        V5_FILL_DELEGATE_SEED, V5_MAGIC_PREFIX, V5_SOURCE_DELEGATE, V5_SOURCE_DELEGATE_SEED,
    },
    error::{CommonError, V5Error},
    event::{FillType, FilledRelay, FundsDeposited, RelayExecutionEventInfo},
    state::State,
    utils::{get_current_time, get_relay_hash, hash_non_empty_message, transfer_from},
    v5::{
        codec::{
            decode_strict, decode_v5_adapter_input, resolve_v5_input_amount, AcrossDepositInput, GatewayContextV1,
            V5AdapterInput, V5FillInput, V5FillJit,
        },
        jit::{derive_v5_deposit_id, resolve_v5_deposit_modifications},
        pda::{find_v5_account, require_gateway_dispatch_authority},
    },
};

use super::{create_v5_fill_status_account, V5FillStatusPdas};

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
        V5AdapterInput::FillV1(fill_input) => execute_v5_fill(ctx, ctx_values, fill_input, &jit_data),
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
        V5_SOURCE_DELEGATE_SEED,
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

fn execute_v5_fill<'info>(
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
    let accounts = load_v5_fill_accounts(
        ctx.remaining_accounts,
        &fill_input,
        relay.output_amount,
        &ctx_values.submitter,
        &relay_hash,
    )?;
    let event = complete_v5_fill(accounts, &ctx.accounts.state, &jit, ctx_values.submitter)?;

    emit_cpi!(event);
    Ok(())
}

enum FillDelivery<'info> {
    Delegated(AccountInfo<'info>),
    InPlace,
}

struct V5FillAccounts<'a, 'info> {
    from: AccountInfo<'info>,
    recipient: AccountInfo<'info>,
    delivery: FillDelivery<'info>,
    mint: AccountInfo<'info>,
    token_program: AccountInfo<'info>,
    mint_decimals: u8,
    payer: AccountInfo<'info>,
    fill_status: AccountInfo<'info>,
    system_program: AccountInfo<'info>,
    fill_status_pdas: V5FillStatusPdas<'a>,
}

// Preserve a separate SBF frame; inlining event construction can push the fill handler past the 4 KiB limit.
#[inline(never)]
fn complete_v5_fill(
    accounts: V5FillAccounts<'_, '_>,
    state: &State,
    jit: &V5FillJit,
    submitter: Pubkey,
) -> Result<FilledRelay> {
    let relay_data = &jit.relay_data;
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
    let fill_status = create_v5_fill_status_account(
        &accounts.payer,
        &accounts.fill_status,
        &accounts.system_program,
        &accounts.fill_status_pdas,
    )?;

    // Only authenticated in-place delivery skips the token transfer.
    match accounts.delivery {
        FillDelivery::Delegated(delegate) => transfer_from(
            TransferChecked { from: accounts.from, mint: accounts.mint, to: accounts.recipient, authority: delegate },
            accounts.token_program,
            relay_data.output_amount,
            accounts.mint_decimals,
            V5_FILL_DELEGATE_SEED,
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
        repayment_chain_id: jit.repayment_chain_id,
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        relayer: jit.repayment_address,
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message_hash,
        relay_execution_info: RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message_hash: [0; 32],
            updated_output_amount: relay_data.output_amount,
            fill_type: FillType::FastFill,
        },
    })
}

fn load_v5_fill_accounts<'a, 'info>(
    remaining_accounts: &[AccountInfo<'info>],
    fill_input: &V5FillInput,
    output_amount: u64,
    submitter: &'a Pubkey,
    relay_hash: &'a [u8; 32],
) -> Result<V5FillAccounts<'a, 'info>> {
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
    let source =
        load_token_account(gateway_vault_info, &token_program_id, &fill_input.output_token, &GATEWAY_VAULT_AUTHORITY)?;
    load_token_account(recipient_info, &token_program_id, &fill_input.output_token, &fill_input.recipient)?;

    let delivery = if gateway_vault == recipient {
        // This check is not a debit. Builders must consume after one fill or enforce an aggregate floor covering
        // every in-place fill recorded before full-balance consumption; step-root reuse alone is valid.
        require!(source.amount >= output_amount, V5Error::InsufficientVaultBalance);
        FillDelivery::InPlace
    } else {
        require!(source.delegate == COption::Some(V5_FILL_DELEGATE), V5Error::InvalidTokenAccount);
        FillDelivery::Delegated(find_v5_account(remaining_accounts, &V5_FILL_DELEGATE, false)?.clone())
    };

    let fill_status_pdas = V5FillStatusPdas::derive(submitter, relay_hash);
    let payer_info = find_v5_account(remaining_accounts, &fill_status_pdas.payer(), true)?;
    let fill_status_info = find_v5_account(remaining_accounts, &fill_status_pdas.fill_status(), true)?;
    let system_program_info = find_v5_account(remaining_accounts, &anchor_lang::system_program::ID, false)?;

    Ok(V5FillAccounts {
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
        let source_delegate_info = find_v5_account(remaining_accounts, &V5_SOURCE_DELEGATE, false)?;

        // Canonical ATA addresses plus these owner, mint, and authority checks mirror the static associated-token
        // constraints.
        let source = load_token_account(gateway_vault_info, &token_program_id, &input_token, &GATEWAY_VAULT_AUTHORITY)?;
        load_token_account(spoke_vault_info, &token_program_id, &input_token, &state)?;
        require!(source.delegate == COption::Some(V5_SOURCE_DELEGATE), V5Error::InvalidTokenAccount);

        Ok((
            Self {
                transfer: TransferChecked {
                    from: gateway_vault_info.clone(),
                    mint: mint_info.clone(),
                    to: spoke_vault_info.clone(),
                    authority: source_delegate_info.clone(),
                },
                token_program: token_program.clone(),
                mint_decimals,
            },
            source,
        ))
    }
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

fn validate_v5_mint(info: &AccountInfo, token_program: &Pubkey) -> Result<u8> {
    let data = info.try_borrow_data()?;
    let mint = StateWithExtensions::<SplMint>::unpack(&data).map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    if *token_program == anchor_spl::token_2022::ID {
        let extensions = mint
            .get_extension_types()
            .map_err(|_| error!(V5Error::InvalidTokenAccount))?;
        require!(extensions.iter().all(is_supported_v5_mint_extension), V5Error::UnsupportedTokenExtension);
    }
    Ok(mint.base.decimals)
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
