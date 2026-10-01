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
    utils::{get_current_time, transfer_from},
};

pub struct DepositAccounts<'info> {
    pub transfer: TransferChecked<'info>,
    pub token_program: AccountInfo<'info>,
    pub mint_decimals: u8,
}

/// Validates the deposit, transfers tokens to the vault, and constructs the event with the adapter-derived deposit ID.
/// The instruction handler emits the event because Anchor's `emit_cpi!` macro requires its concrete `ctx` in scope.
pub fn _deposit(
    accounts: DepositAccounts,
    state: &State,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: [u8; 32],
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    deposit_id: [u8; 32],
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_parameter: u32,
    message: Vec<u8>,
    delegate_seed: &[u8],
) -> Result<FundsDeposited> {
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
    transfer_from(accounts.transfer, accounts.token_program, input_amount, accounts.mint_decimals, delegate_seed)?;

    Ok(FundsDeposited {
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        deposit_id,
        quote_timestamp,
        fill_deadline,
        exclusivity_deadline,
        depositor,
        recipient,
        exclusive_relayer,
        message,
    })
}
