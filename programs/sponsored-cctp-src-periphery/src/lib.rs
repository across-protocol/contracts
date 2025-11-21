#![allow(unexpected_cfgs)]

mod error;
mod event;
mod instructions;
mod state;
mod utils;

use anchor_lang::prelude::*;

use instructions::*;
use utils::*;

#[cfg(not(feature = "no-entrypoint"))]
solana_security_txt::security_txt! {
    name: "Across Sponsored CCTP Source Periphery",
    project_url: "https://across.to",
    contacts: "email:bugs@across.to",
    policy: "https://docs.across.to/resources/bug-bounty",
    preferred_languages: "en",
    source_code: "https://github.com/across-protocol/contracts/tree/master/programs/sponsored-cctp-src-periphery",
    auditors: "OpenZeppelin"
}

// If changing the program ID, make sure to check that the resulting rent_fund PDA has the highest bump of 255 so to
// minimize the compute cost when finding the PDA. The reason for not persisting rent_fund PDA bump in its state is that
// it is used as a payer for CCTP MessageSent event account creation, so it cannot contain any data.
declare_id!("CPr4bRvkVKcSCLyrQpkZrRrwGzQeVAXutFU8WupuBLXq");

// External programs from idls directory (requires anchor run generateExternalTypes).
declare_program!(message_transmitter_v2);
declare_program!(token_messenger_minter_v2);

/// # Across Sponsored CCTP Source Periphery
///
/// Source chain periphery program for users to interact with to start a sponsored or a non-sponsored flow that allows
/// custom Across-supported flows on destination chain. Uses Circle's CCTPv2 as an underlying bridge

#[program]
pub mod sponsored_cctp_src_periphery {
    use super::*;

    /// Initializes immutable program state and sets the trusted EVM quote signer.
    ///
    /// This can only be called once by the upgrade authority. It stores the local CCTP source domain and the
    /// quote `signer` that must authorize sponsored deposits.
    ///
    /// Required Accounts:
    /// - signer (Signer, Writable): Must be the program upgrade authority.
    /// - state (Writable): Program state PDA. Seed: ["state"].
    /// - program_data (Account): Program data account to verify the upgrade authority.
    /// - this_program (Program): This program account, used to resolve `programdata_address`.
    /// - system_program (Program): System program for account creation.
    ///
    /// Parameters:
    /// - source_domain: CCTP domain for this chain (e.g., 5 for Solana).
    /// - signer: EVM address (encoded as `Pubkey`) authorized to sign sponsored quotes.
    pub fn initialize(ctx: Context<Initialize>, params: InitializeParams) -> Result<()> {
        instructions::initialize(ctx, &params)
    }

    /// Updates the trusted EVM quote signer.
    ///
    /// Only callable by the upgrade authority. Setting this to an invalid address (including `Pubkey::default()`) will
    /// effectively disable deposits.
    ///
    /// Required Accounts:
    /// - signer (Signer, Writable): Must be the program upgrade authority.
    /// - state (Writable): Program state PDA. Seed: ["state"].
    /// - program_data (Account): Program data account to verify the upgrade authority.
    /// - this_program (Program): This program account, used to resolve `programdata_address`.
    ///
    /// Parameters:
    /// - new_signer: New EVM signer address (encoded as `Pubkey`).
    pub fn set_signer(ctx: Context<SetSigner>, params: SetSignerParams) -> Result<()> {
        instructions::set_signer(ctx, &params)
    }

    /// Withdraws lamports from the rent fund PDA to an arbitrary recipient.
    ///
    /// The rent fund is used to sponsor temporary account creation (e.g., CCTP event accounts or per-quote nonce PDAs).
    /// Only callable by the upgrade authority.
    ///
    /// Required Accounts:
    /// - signer (Signer, Writable): Must be the program upgrade authority.
    /// - rent_fund (SystemAccount, Writable): PDA holding lamports used for rent sponsorship. Seed: ["rent_fund"].
    /// - recipient (UncheckedAccount, Writable): Destination account for the withdrawn lamports.
    /// - program_data (Account): Program data account to verify the upgrade authority.
    /// - this_program (Program): This program account, used to resolve `programdata_address`.
    /// - system_program (Program): System program for transfers.
    ///
    /// Parameters:
    /// - amount: Amount of lamports to transfer to the recipient.
    pub fn withdraw_rent_fund(ctx: Context<WithdrawRentFund>, params: WithdrawRentFundParams) -> Result<()> {
        instructions::withdraw_rent_fund(ctx, &params)
    }

    /// Updates the minimum deposit amount for a given burn token.
    ///
    /// Only callable by the upgrade authority. This must be set at least once for a supported burn token as otherwise
    /// deposits would be blocked.
    ///
    /// Required Accounts:
    /// - signer (Signer, Writable): Must be the program upgrade authority.
    /// - minimum_deposit (Writable): Minimum deposit state PDA. Seed: ["minimum_deposit", burn_token.key()].
    /// - burn_token: Supported burn token for which the minimum deposit amount is being set.
    /// - program_data (Account): Program data account to verify the upgrade authority.
    /// - this_program (Program): This program account, used to resolve `programdata_address`.
    /// - system_program (Program): System program for transfers.
    ///
    /// Parameters:
    /// - amount: New minimum deposit amount for a given burn token.
    pub fn set_minimum_deposit_amount(
        ctx: Context<SetMinimumDepositAmount>,
        params: SetMinimumDepositAmountParams,
    ) -> Result<()> {
        instructions::set_minimum_deposit_amount(ctx, &params)
    }

    /// Verifies a sponsored CCTP quote, records its nonce, and burns the user's tokens via CCTPv2 with hook data.
    ///
    /// The user's depositor ATA is burned via `deposit_for_burn_with_hook` CPI on the CCTPv2. The rent cost for the
    /// per-quote `used_nonce` PDA is refunded to the signer from the `rent_fund` and `rent_fund` also funds the
    /// creation of CCTP `MessageSent` event account.
    /// On success, this emits a `SponsoredDepositForBurn` event to be consumed by offchain infrastructure. This also
    /// emits a `CreatedEventAccount` event containing the address of the created CCTP `MessageSent` event account that
    /// can be reclaimed later using the `reclaim_event_account` instruction.
    ///
    /// Required Accounts:
    /// - signer (Signer, Writable): The user authorizing the burn.
    /// - state (Account): Program state PDA. Seed: ["state"].
    /// - rent_fund (SystemAccount, Writable): PDA used to sponsor rent and event accounts. Seed: ["rent_fund"].
    /// - minimum_deposit (Account): Minimum deposit state PDA. Seed: ["minimum_deposit", burn_token.key()].
    /// - used_nonce (Account, Writable, Init): Per-quote nonce PDA. Seed: ["used_nonce", nonce].
    /// - rent_claim (Optional Account, Writable, Init-If-Needed): Optional PDA to accrue rent_fund debt to the user.
    ///   Seed: ["rent_claim", signer.key()].
    /// - depositor_token_account (InterfaceAccount<TokenAccount>, Writable): Signer ATA of the burn token.
    /// - burn_token (InterfaceAccount<Mint>, Mutable): Mint of the token to burn. Must match quote.burn_token.
    /// - denylist_account (Unchecked): CCTP denylist PDA, validated within CCTP.
    /// - token_messenger_minter_sender_authority (Unchecked): CCTP sender authority PDA.
    /// - message_transmitter (Unchecked, Mutable): CCTP MessageTransmitter account.
    /// - token_messenger (Unchecked): CCTP TokenMessenger account.
    /// - remote_token_messenger (Unchecked): Remote TokenMessenger account for destination domain.
    /// - token_minter (Unchecked): CCTP TokenMinter account.
    /// - local_token (Unchecked, Mutable): Local token account (CCTP).
    /// - cctp_event_authority (Unchecked): CCTP event authority account.
    /// - message_sent_event_data (Signer, Mutable): Fresh account to store CCTP MessageSent event data.
    /// - message_transmitter_program (Program): CCTPv2 MessageTransmitter program.
    /// - token_messenger_minter_program (Program): CCTPv2 TokenMessengerMinter program.
    /// - token_program (Interface): SPL token program.
    /// - system_program (Program): System program.
    ///
    /// Parameters:
    /// - quote: ABI-encoded quote bytes (fixed length) containing burn parameters and hook data.
    /// - signature: 65-byte EVM signature authorizing the quote by the trusted signer.
    ///
    /// Notes:
    /// - The upgrade authority must have set the valid EVM signer for this instruction to succeed.
    /// - The operator of this program must have funded the `rent_fund` PDA with sufficient lamports to cover
    ///   rent for the `used_nonce` PDA and the CCTP `MessageSent` event account.
    pub fn deposit_for_burn(ctx: Context<DepositForBurn>, params: DepositForBurnParams) -> Result<()> {
        instructions::deposit_for_burn(ctx, &params)
    }

    /// Repays rent_fund liability for a user if rent_fund had insufficient balance at the time of deposit.
    ///
    /// Required Accounts:
    /// - rent_fund (SystemAccount, Writable): PDA used to sponsor rent and event accounts. Seed: ["rent_fund"].
    /// - recipient (Unchecked, Writable): The user account to repay rent fund debt to.
    /// - rent_claim (Account, Writable, Close=recipient): PDA with accrued rent_fund debt to the user.
    ///   Seed: ["rent_claim", recipient.key()].
    /// - system_program (Program): System program.
    pub fn repay_rent_fund_debt(ctx: Context<RepayRentFundDebt>) -> Result<()> {
        instructions::repay_rent_fund_debt(ctx)
    }

    /// Reclaims the CCTP `MessageSent` event account, returning rent to the rent fund.
    ///
    /// Required Accounts:
    /// - rent_fund (SystemAccount, Writable): PDA to receive reclaimed lamports. Seed: ["rent_fund"].
    /// - message_transmitter (Unchecked, Mutable): CCTP MessageTransmitter account.
    /// - message_sent_event_data (Unchecked, Mutable): The event account created during `deposit_for_burn`.
    /// - message_transmitter_program (Program): CCTPv2 MessageTransmitter program.
    ///
    /// Parameters:
    /// - params: Parameters required by CCTP to reclaim the event account.
    ///
    /// Notes:
    /// - This can only be called after the CCTP attestation service has processed the message and sufficient time has
    ///   passed since the `MessageSent` event was created. The operator can track the closable accounts from the
    ///   emitted `CreatedEventAccount` events and using the `EVENT_ACCOUNT_WINDOW_SECONDS` set in CCTP program.
    pub fn reclaim_event_account(ctx: Context<ReclaimEventAccount>, params: ReclaimEventAccountParams) -> Result<()> {
        instructions::reclaim_event_account(ctx, &params)
    }

    /// Closes a `used_nonce` PDA once its quote deadline has passed, returning rent to the rent fund.
    ///
    /// Required Accounts:
    /// - state (Account): Program state PDA. Seed: ["state"]. Used to fetch current time.
    /// - rent_fund (SystemAccount, Writable): PDA receiving lamports upon close. Seed: ["rent_fund"].
    /// - used_nonce (Account, Writable, Close=rent_fund): PDA to close. Seed: ["used_nonce", nonce].
    ///
    /// Parameters:
    /// - params.nonce: The 32-byte nonce identifying the PDA to close.
    ///
    /// Notes:
    /// - This can only be called after the quote's deadline has passed. The operator can track closable `used_nonce`
    ///   accounts from the emitted `SponsoredDepositForBurn` events (`quote_nonce` and `quote_deadline`) and using the
    ///   `get_used_nonce_close_info` helper.
    pub fn reclaim_used_nonce_account(
        ctx: Context<ReclaimUsedNonceAccount>,
        params: UsedNonceAccountParams,
    ) -> Result<()> {
        instructions::reclaim_used_nonce_account(ctx, &params)
    }

    /// Returns whether a `used_nonce` PDA can be closed now and the timestamp after which it can be closed.
    ///
    /// This is a convenience "view" helper for off-chain systems to determine when rent can be reclaimed for a
    /// specific quote nonce.
    ///
    /// Required Accounts:
    /// - state (Account): Program state PDA. Seed: ["state"].
    /// - used_nonce (Account): The `used_nonce` PDA. Seed: ["used_nonce", nonce].
    ///
    /// Parameters:
    /// - _params.nonce: The 32-byte nonce identifying the PDA to check.
    ///
    /// Returns:
    /// - UsedNonceCloseInfo { can_close_after, can_close_now }
    pub fn get_used_nonce_close_info(
        ctx: Context<GetUsedNonceCloseInfo>,
        _params: UsedNonceAccountParams,
    ) -> Result<UsedNonceCloseInfo> {
        instructions::get_used_nonce_close_info(ctx)
    }

    /// Sets the current time in test mode. No-op on mainnet builds.
    ///
    /// Required Accounts:
    /// - state (Writable): Program state PDA. Seed: ["state"].
    /// - signer (Signer): Any signer. Only enabled when built with `--features test`.
    ///
    /// Parameters:
    /// - new_time: New unix timestamp to set for tests.
    pub fn set_current_time(ctx: Context<SetCurrentTime>, params: SetCurrentTimeParams) -> Result<()> {
        utils::set_current_time(ctx, params)
    }
}
