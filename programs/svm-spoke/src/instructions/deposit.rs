// Note: The `svm-spoke` does not support `speedUpDeposit` and `fillRelayWithUpdatedDeposit` due to cryptographic
// incompatibilities between Solana (Ed25519) and Ethereum (ECDSA secp256k1). Specifically, Solana wallets cannot
// generate ECDSA signatures required for Ethereum verification. As a result, speed-up functionality on Solana is not
// implemented. For more details, refer to the documentation: https://docs.across.to

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::MAX_EXCLUSIVITY_PERIOD_SECONDS,
    error::{CommonError, SvmError},
    event::FundsDeposited,
    state::State,
    utils::{
        derive_seed_hash, get_current_time, get_unsafe_deposit_id, transfer_from_with_delegate, DelegatePda,
        DepositNowSeedData, DepositSeedData,
    },
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(depositor: Pubkey, recipient: Pubkey, input_token: Pubkey)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        mut,
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_deposits @ CommonError::DepositsArePaused
    )]
    pub state: Account<'info, State>,

    /// CHECK: PDA derived with seeds ["delegate", seed_hash]; used as a CPI signer.
    pub delegate: UncheckedAccount<'info>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = depositor,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = signer,
        associated_token::mint = mint,
        associated_token::authority = state, // Ensure owner is the state as tokens are sent here on deposit.
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mint::token_program = token_program,
        constraint = mint.key() == input_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    pub token_program: Interface<'info, TokenInterface>,

    pub associated_token_program: Program<'info, AssociatedToken>,

    pub system_program: Program<'info, System>,
}

pub struct DepositAccounts<'info> {
    pub from: AccountInfo<'info>,
    pub vault: AccountInfo<'info>,
    pub delegate: AccountInfo<'info>,
    pub mint: AccountInfo<'info>,
    pub token_program: AccountInfo<'info>,
    pub mint_decimals: u8,
}

impl<'info> From<&Deposit<'info>> for DepositAccounts<'info> {
    fn from(accounts: &Deposit<'info>) -> Self {
        Self {
            from: accounts.depositor_token_account.to_account_info(),
            vault: accounts.vault.to_account_info(),
            delegate: accounts.delegate.to_account_info(),
            mint: accounts.mint.to_account_info(),
            token_program: accounts.token_program.to_account_info(),
            mint_decimals: accounts.mint.decimals,
        }
    }
}

pub enum DepositId<'a> {
    Next(&'a mut State),
    Fixed { state: &'a State, value: [u8; 32] },
}

/// Executes shared deposit validation and the vault transfer, resolves the deposit ID, and constructs the canonical
/// deposit event.
/// The instruction handler emits the event because Anchor's `emit_cpi!` macro requires its concrete `ctx` in scope.
pub fn _deposit(
    accounts: DepositAccounts,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_id: DepositId<'_>,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
    delegate_pda: DelegatePda,
) -> Result<FundsDeposited> {
    let state = match &deposit_id {
        DepositId::Next(state) => &**state,
        DepositId::Fixed { state, .. } => *state,
    };

    let current_time = get_current_time(state)?;

    if output_token == Pubkey::default() {
        return err!(CommonError::InvalidOutputToken);
    }

    if current_time.checked_sub(quote_timestamp).unwrap_or(u32::MAX) > state.deposit_quote_time_buffer {
        return err!(CommonError::InvalidQuoteTimestamp);
    }
    if fill_deadline > current_time + state.fill_deadline_buffer {
        return err!(CommonError::InvalidFillDeadline);
    }

    let mut exclusivity_deadline = exclusivity_parameter;
    if exclusivity_deadline > 0 {
        if exclusivity_deadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS {
            exclusivity_deadline += current_time;
        }
        if exclusive_relayer == Pubkey::default() {
            return err!(CommonError::InvalidExclusiveRelayer);
        }
    }

    // Depositor must have delegated input_amount to the delegate PDA
    transfer_from_with_delegate(
        TransferChecked { from: accounts.from, mint: accounts.mint, to: accounts.vault, authority: accounts.delegate },
        accounts.token_program,
        input_amount,
        accounts.mint_decimals,
        delegate_pda,
    )?;

    let applied_deposit_id = match deposit_id {
        DepositId::Next(state) => {
            // Sequential deposits use the state's number of deposits as deposit_id.
            state.number_of_deposits += 1;
            let mut applied_deposit_id = [0u8; 32];
            applied_deposit_id[28..].copy_from_slice(&state.number_of_deposits.to_be_bytes());
            applied_deposit_id
        }
        DepositId::Fixed { value, .. } => value,
    };

    Ok(FundsDeposited {
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        deposit_id: applied_deposit_id,
        quote_timestamp,
        fill_deadline,
        exclusivity_deadline,
        depositor,
        recipient,
        exclusive_relayer,
        message,
    })
}

pub fn deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    let seed_hash = derive_seed_hash(
        &(DepositSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            quote_timestamp,
            fill_deadline,
            exclusivity_parameter,
            message: &message,
        }),
    );
    let accounts = DepositAccounts::from(&*ctx.accounts);
    let event = _deposit(
        accounts,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        DepositId::Next(&mut ctx.accounts.state),
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
        DelegatePda::UniqueHash(seed_hash),
    )?;
    emit_cpi!(event);
    Ok(())
}

pub fn deposit_now(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    fill_deadline_offset: u32,
    exclusivity_period: u32,
    message: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let current_time = get_current_time(state)?;
    let seed_hash = derive_seed_hash(
        &(DepositNowSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            fill_deadline_offset,
            exclusivity_period,
            message: &message,
        }),
    );
    let accounts = DepositAccounts::from(&*ctx.accounts);
    let event = _deposit(
        accounts,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        DepositId::Next(&mut ctx.accounts.state),
        current_time,
        current_time + fill_deadline_offset,
        exclusivity_period,
        message,
        DelegatePda::UniqueHash(seed_hash),
    )?;
    emit_cpi!(event);
    Ok(())
}

pub fn unsafe_deposit(
    ctx: Context<Deposit>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_nonce: u64,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> Result<()> {
    // Calculate the unsafe deposit ID as a [u8; 32]
    let deposit_id = get_unsafe_deposit_id(ctx.accounts.signer.key(), depositor, deposit_nonce);
    let seed_hash = derive_seed_hash(
        &(DepositSeedData {
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            quote_timestamp,
            fill_deadline,
            exclusivity_parameter,
            message: &message,
        }),
    );
    let accounts = DepositAccounts::from(&*ctx.accounts);
    let event = _deposit(
        accounts,
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        DepositId::Fixed { state: &ctx.accounts.state, value: deposit_id },
        quote_timestamp,
        fill_deadline,
        exclusivity_parameter,
        message,
        DelegatePda::UniqueHash(seed_hash),
    )?;
    emit_cpi!(event);
    Ok(())
}
