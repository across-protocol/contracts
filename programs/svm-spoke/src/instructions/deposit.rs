// Note: The `svm-spoke` does not support `speedUpDeposit` and `fillRelayWithUpdatedDeposit` due to cryptographic
// incompatibilities between Solana (Ed25519) and Ethereum (ECDSA secp256k1). Specifically, Solana wallets cannot
// generate ECDSA signatures required for Ethereum verification. As a result, speed-up functionality on Solana is not
// implemented. For more details, refer to the documentation: https://docs.across.to

use anchor_lang::prelude::*;
use anchor_spl::token_interface::TransferChecked;

use crate::{
    constants::MAX_EXCLUSIVITY_PERIOD_SECONDS,
    error::CommonError,
    event::FundsDeposited,
    state::State,
    utils::{get_current_time, transfer_from, DelegatePda},
};

pub struct DepositAccounts<'info> {
    pub transfer: TransferChecked<'info>,
    pub token_program: AccountInfo<'info>,
    pub mint_decimals: u8,
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
    transfer_from(accounts.transfer, accounts.token_program, input_amount, accounts.mint_decimals, delegate_pda)?;

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
