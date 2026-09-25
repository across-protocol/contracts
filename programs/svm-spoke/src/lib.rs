use anchor_lang::prelude::*;

#[cfg(not(feature = "no-entrypoint"))]
use ::solana_security_txt::security_txt;

#[cfg(not(feature = "no-entrypoint"))]
security_txt! {
    name: "Across",
    project_url: "https://across.to",
    contacts: "email:bugs@across.to",
    policy: "https://docs.across.to/resources/bug-bounty",
    preferred_languages: "en",
    source_code: "https://github.com/across-protocol/contracts/tree/master/programs/svm-spoke",
    auditors: "OpenZeppelin"
}

declare_id!("DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru");

/// # Across SVM Spoke Program
///
/// Spoke pool implementation for Across Protocol enabling connection to the Solana Ecosystem. Program is functionally
/// the re-implementation of SpokePool.sol for Solana, with some extensions to be Solana compatible. The implementation
/// leverages Circle's CCTP V2 to receive admin messages from the HubPool on Ethereum mainnet. As the EVM spoke pool,
/// this spoke pool is instructed by the EVM hubpool for relayer repayment. Tokens are never bridged back to the HubPool.
///
/// For any issues, please reach out to bugs@across.to.
pub mod common;
pub mod constants;
mod constraints;
pub mod error;
pub mod event;
mod instructions;
mod state;
pub mod utils;
pub mod v5;

use instructions::*;
use utils::*;
use v5::codec::GatewayContextV1;

#[cfg(test)]
mod tests;

#[program]
pub mod svm_spoke {
    use super::*;

    // **************************************
    //            ADMIN FUNCTIONS           *
    // *************************************

    /// Initializes the state for the SVM Spoke Pool. Only callable once.
    ///
    /// ### Required Accounts:
    /// - signer (Writable, Signer): The account that pays for the transaction and will own the state.
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - system_program: The system program required for account creation.
    ///
    /// ### Parameters:
    /// - seed: A unique seed used to derive the state account's address. Must be 0 on Mainnet.
    /// - initial_number_of_deposits: The initial number of deposits. Used to offset in upgrades.
    /// - chain_id: The chain ID for Solana, used to identify the Solana spoke in the rest of the Across protocol.
    /// - remote_domain: The CCTP domain for Mainnet Ethereum.
    /// - cross_domain_admin: The HubPool on Mainnet Ethereum.
    /// - deposit_quote_time_buffer: Quote timestamps can't be set more than this amount into the past from deposit.
    /// - fill_deadline_buffer: Fill deadlines can't be set more than this amount into the future from deposit.
    pub fn initialize(
        ctx: Context<Initialize>,
        seed: u64,
        initial_number_of_deposits: u32,
        chain_id: u64,
        remote_domain: u32,
        cross_domain_admin: Pubkey,
        deposit_quote_time_buffer: u32,
        fill_deadline_buffer: u32,
    ) -> Result<()> {
        instructions::initialize(
            ctx,
            seed,
            initial_number_of_deposits,
            chain_id,
            remote_domain,
            cross_domain_admin,
            deposit_quote_time_buffer,
            fill_deadline_buffer,
        )
    }

    /// Pauses the Spoke Pool from accepting deposits. Only callable by the owner.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the pause.
    /// - state (Writable): The Spoke state PDA. Seed: ["state",state.seed], where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - pause: `true` to pause the system, `false` to unpause it.
    pub fn pause_deposits(ctx: Context<PauseDeposits>, pause: bool) -> Result<()> {
        instructions::pause_deposits(ctx, pause)
    }

    /// Pauses the Spoke Pool from processing fills. Only callable by the owner.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the pause.
    /// - state (Writable): The Spoke state PDA. Seed: ["state",state.seed], where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - pause: `true` to pause the system, `false` to unpause it.
    pub fn pause_fills(ctx: Context<PauseFills>, pause: bool) -> Result<()> {
        instructions::pause_fills(ctx, pause)
    }

    /// Transfers ownership of the Spoke Pool. Only callable by the current owner.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the current owner to authorize the transfer.
    /// - state (Writable): The Spoke state PDA. Seed: ["state",state.seed] where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - new_owner: The public key of the new owner.
    pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
        instructions::transfer_ownership(ctx, new_owner)
    }

    /// Sets the cross-domain admin for the Spoke Pool. Only callable by owner. Used if Hubpool upgrades.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the admin change.
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - cross_domain_admin: The public key of the new cross-domain admin.
    pub fn set_cross_domain_admin(ctx: Context<SetCrossDomainAdmin>, cross_domain_admin: Pubkey) -> Result<()> {
        instructions::set_cross_domain_admin(ctx, cross_domain_admin)
    }

    /// Stores a new root bundle for later execution. Only callable by the owner.
    ///
    /// The refund root authorizes relayer refunds. The slow root is stored only for compatibility and cannot execute.
    /// This method initializes a root_bundle PDA to store the root bundle data. The caller
    /// of this method is responsible for paying the rent for this PDA.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the addition of the new root bundle.
    /// - payer (Signer): The account who pays rent to create root_bundle PDA.
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The newly created bundle PDA to store root bundle data. Each root bundle has an
    ///   incrementing ID, stored in the state. Seed: ["root_bundle",state.seed,root_bundle_id].
    /// - system_program (Program): The system program required for account creation.
    ///
    /// ### Parameters:
    /// - relayer_refund_root: Merkle root of the relayer refund tree.
    /// - slow_relay_root: Inert legacy root retained for cross-chain admin ABI compatibility.
    pub fn relay_root_bundle(
        ctx: Context<RelayRootBundle>,
        relayer_refund_root: [u8; 32],
        slow_relay_root: [u8; 32],
    ) -> Result<()> {
        instructions::relay_root_bundle(ctx, relayer_refund_root, slow_relay_root)
    }

    /// Deletes a root bundle in case of emergencies where bad bundle has reached the Spoke. Only callable by the owner.
    ///
    /// This function will close the PDA for the associated `root_bundle_id`.
    /// Note: Using this function does not decrement `state.root_bundle_id`.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the deletion.
    /// - closer (SystemAccount): The account that will receive the lamports from closing the root_bundle account.
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The root bundle PDA to be closed. Seed: ["root_bundle",state.seed,root_bundle_id].
    ///
    /// ### Parameters:
    /// - root_bundle_id: Index of the root bundle that needs to be deleted.
    pub fn emergency_delete_root_bundle(
        ctx: Context<EmergencyDeleteRootBundleState>,
        root_bundle_id: u32,
    ) -> Result<()> {
        instructions::emergency_delete_root_bundle(ctx, root_bundle_id)
    }

    // **************************************
    //              V5 ADAPTER              *
    // *************************************

    /// Executes one Gateway-authenticated Across V5 source-deposit or destination-fill adapter branch.
    ///
    /// ### Required Accounts:
    /// - dispatch_authority (Signer): Gateway PDA derived from ["dispatch_authority", svm_spoke::ID].
    /// - state: Spoke state PDA derived from ["state", state.seed], where `state.seed` is 0 on mainnet.
    /// - event_authority: Anchor event CPI authority derived from ["__event_authority"].
    /// - program: The SVM Spoke program.
    /// - remaining accounts: Branch-specific mint and token-program accounts plus writable canonical token accounts.
    ///   Deposit mode also requires the SpokePool vault and ["v5_source_delegate"]. Fill mode requires the
    ///   submitter-scoped ["v5_fill_payer"], relay-scoped fill-status PDA, and System Program; external delivery also
    ///   requires the recipient ATA and ["v5_fill_delegate"]. Account order is unrestricted because each account is
    ///   resolved by its authenticated expected key.
    ///
    /// ### Parameters:
    /// - ctx_values: Gateway-attested step ID, path ID, and submitter.
    /// - input: Strictly encoded, versioned `DepositV1 | FillV1` committed input.
    /// - jit_data: Source modifications decoded only when the committed input enables them, or destination
    ///   relay/repayment data.
    pub fn adapter_execute_across_v5<'info>(
        ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
        ctx_values: GatewayContextV1,
        input: Vec<u8>,
        jit_data: Vec<u8>,
    ) -> Result<()> {
        instructions::adapter_execute_across_v5(ctx, ctx_values, input, jit_data)
    }

    // **************************************
    //          RELAYER FUNCTIONS           *
    // *************************************

    /// Closes the FillStatusAccount PDA to reclaim relayer rent.
    ///
    /// This function is used to close the FillStatusAccount associated with a specific relay hash, effectively marking
    /// the end of its lifecycle. This can only be done once the fill deadline has passed. Anyone can trigger closure,
    /// but rent is always returned to the recorded relayer.
    ///
    /// ### Required Accounts:
    /// - signer (Writable): The recorded relayer that receives rent; no signature is required.
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - fill_status (Writable): The FillStatusAccount PDA to be closed.
    pub fn close_fill_pda(ctx: Context<CloseFillPda>) -> Result<()> {
        instructions::close_fill_pda(ctx)
    }

    /// Withdraws lamports from the signing submitter's V5 fill-status payer float back to that same submitter. Partial
    /// withdrawals remain subject to the runtime's rent-state rules; `u64::MAX` withdraws the live balance.
    pub fn withdraw_v5_fill_payer(ctx: Context<WithdrawV5FillPayer>, amount: u64) -> Result<()> {
        instructions::withdraw_v5_fill_payer(ctx, amount)
    }

    #[cfg(feature = "test")]
    pub fn test_create_v5_fill_status(
        ctx: Context<TestCreateV5FillStatus>,
        relay_hash: [u8; 32],
        fill_deadline: u32,
    ) -> Result<()> {
        instructions::test_create_v5_fill_status(ctx, relay_hash, fill_deadline)
    }

    /// Claims a relayer refund for the caller.
    ///
    /// In the event a relayer refund was sent to a claim account, then this function enables the relayer to claim it by
    /// transferring the claim amount from the vault to their token account. The claim account is closed after refund.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that authorizes the claim.
    /// - initializer (UncheckedAccount): Must be the same account that initialized the claim account.
    /// - state (Account): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - vault (InterfaceAccount): The ATA for the refunded mint. Authority must be the state.
    /// - mint (InterfaceAccount): The mint account for the token being refunded.
    /// - refund_address: token account authority receiving the refund.
    /// - token_account (InterfaceAccount): The receiving token account for the refund. When refund_address is different
    ///   from the signer, this must match its ATA.
    /// - claim_account (Account): The claim account PDA. Seed: ["claim_account",mint,refund_address].
    /// - token_program (Interface): The token program.
    pub fn claim_relayer_refund(ctx: Context<ClaimRelayerRefund>) -> Result<()> {
        instructions::claim_relayer_refund(ctx)
    }

    /// Creates token accounts in batch for a set of addresses.
    ///
    /// This helper function allows the caller to pass in a set of remaining accounts to create a batch of Associated
    /// Token Accounts (ATAs) for addresses. It is particularly useful for relayers to call before filling a deposit.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that authorizes the creation of token accounts.
    /// - mint (InterfaceAccount): The mint account for the token.
    /// - token_program (Interface): The token program.
    /// - associated_token_program (Program): The associated token program.
    /// - system_program (Program): The system program required for account creation.
    pub fn create_token_accounts<'info>(ctx: Context<'_, '_, '_, 'info, CreateTokenAccounts<'info>>) -> Result<()> {
        instructions::create_token_accounts(ctx)
    }

    // **************************************
    //           BUNDLE FUNCTIONS           *
    // *************************************

    /// Executes relayer refund leaf.
    ///
    /// Processes a relayer refund leaf, verifying its inclusion in a previous Merkle root and that it was not
    /// previously executed. Function has two modes of operation: a) transfers all relayer refunds directly to
    /// relayers ATA or b) credits relayers with claimable claim_account PDA that they can use later to claim their
    /// refund. In the happy path, (a) should be used. (b) should only be used if there is a relayer within the bundle
    /// who can't receive the transfer for some reason, such as failed token transfers due to blacklisting. Executing
    /// relayer refunds requires the caller to create a LUT and load the execution params into it. This is needed to
    /// fit the data in a single instruction. The exact structure and validation of the leaf is defined in the Across
    /// UMIP: https://github.com/UMAprotocol/UMIPs/blob/master/UMIPs/umip-179.md
    ///
    /// instruction_params Parameters:
    /// - root_bundle_id: The ID of the root bundle containing the relayer refund root.
    /// - relayer_refund_leaf: The relayer refund leaf to be executed. Contents must include:
    ///     - amount_to_return: Must be 0 as this Spoke pool never returns tokens to the HubPool.
    ///     - chain_id: The targeted chainId for the refund. Validated against state.chain_id.
    ///     - refund_amounts: The amounts to be returned to the relayer for each refund_address.
    ///     - leaf_id: The leaf ID of the relayer refund leaf.
    ///     - mint_public_key: The public key of the mint (refunded token) being refunded.
    ///     - refund_addresses: The addresses to be refunded.
    /// - proof: The Merkle proof for the relayer refund leaf.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that authorizes the execution. No permission requirements.
    /// - instruction_params (Account): LUT containing the execution parameters. seed: ["instruction_params",signer]
    /// - state (Writable): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The root bundle PDA containing the relayer refund root, created when the root bundle
    ///   was initially bridged. seed: ["root_bundle",state.seed,root_bundle_id].
    /// - vault (Writable): The ATA for refunded mint. Authority must be the state.
    /// - mint (Account): The mint account for the token being refunded.
    /// - token_program: The token program.
    /// - system_program: The system program required for account creation.
    ///
    /// execute_relayer_refund_leaf executes in mode where refunds are sent to ATA directly.
    pub fn execute_relayer_refund_leaf<'c, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    ) -> Result<()>
    where
        'c: 'info,
    {
        instructions::execute_relayer_refund_leaf(ctx, false)
    }

    /// Similar to execute_relayer_refund_leaf, but executes in mode where refunds are allocated to claim_account PDAs.
    pub fn execute_relayer_refund_leaf_deferred<'c, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    ) -> Result<()>
    where
        'c: 'info,
    {
        instructions::execute_relayer_refund_leaf(ctx, true)
    }

    /// Initializes the instruction parameters account. Used by data worker when relaying bundles
    ///
    /// This function sets up an account to store raw data fragments for instructions (LUT).
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that pays for the transaction and initializes the instruction parameters.
    /// - instruction_params (UncheckedAccount): The account where raw data will be stored. Initialized with specified
    ///   size. seed: ["instruction_params",signer].
    /// - system_program: The system program required for account creation.
    ///
    /// ### Parameters:
    /// - _total_size: The total size of the instruction parameters account.
    pub fn initialize_instruction_params(_ctx: Context<InitializeInstructionParams>, _total_size: u32) -> Result<()> {
        Ok(())
    }

    /// Writes a fragment of raw data into the instruction parameters account.
    ///
    /// This function allows writing a fragment of data into a specified offset within the instruction parameters
    /// account. It ensures that the data does not overflow the account's allocated space.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): Account that authorizes the write operation.
    /// - instruction_params (UncheckedAccount): Account to write raw data to. seed: ["instruction_params",signer].
    /// - system_program: The system program required for account operations.
    ///
    /// ### Parameters:
    /// - offset: The starting position within the account's data where the fragment will be written.
    /// - fragment: The raw data fragment to be written into the account.
    pub fn write_instruction_params_fragment(
        ctx: Context<WriteInstructionParamsFragment<'_>>,
        offset: u32,
        fragment: Vec<u8>,
    ) -> Result<()> {
        instructions::write_instruction_params_fragment(ctx, offset, fragment)
    }

    /// Closes the instruction parameters account.
    ///
    /// This function is used to close the instruction parameters account, effectively marking the end of its lifecycle.
    /// It transfers any remaining lamports to the signer and resets the account.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that authorizes the closure.
    /// - instruction_params (UncheckedAccount): The account to be closed. seed: ["instruction_params",signer]. Not
    ///   the signer being within the seed here implicitly protects this from only being called by the creator.
    pub fn close_instruction_params(ctx: Context<CloseInstructionParams>) -> Result<()> {
        instructions::close_instruction_params(ctx)
    }

    /// Initializes a claim account for a relayer refund.
    ///
    /// This function sets up a claim account for a relayer to claim their refund at a later time and should only be
    /// used in the un-happy path where a bundle cant not be executed due to a recipient in the bundle having a blocked
    /// or uninitialized claim ATA. The refund address becomes the "owner" of the claim_account.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that pays for the transaction and initializes the claim account.
    /// - mint: The mint associated with the claim account.
    /// - refund_address: The refund address associated with the claim account.
    /// - claim_account (Writable): The newly created claim account PDA to store claim data for this associated mint.
    ///   Seed: ["claim_account",mint,refund_address].
    /// - system_program: The system program required for account creation.
    pub fn initialize_claim_account(ctx: Context<InitializeClaimAccount>) -> Result<()> {
        instructions::initialize_claim_account(ctx)
    }

    /// Closes a claim account for a relayer refund.
    ///
    /// This function is used to close the claim account associated with a specific mint and refund address,
    /// effectively marking the end of its lifecycle. It can only be called once the claim account is empty. It
    /// transfers any remaining lamports to the signer and resets the account.
    ///
    /// ### Required Accounts:
    /// - signer (Signer): The account that authorizes the closure. Must be the initializer of the claim account.
    /// - mint: The mint associated with the claim account.
    /// - refund_address: The refund address associated with the claim account.
    /// - claim_account (Writable): The claim account PDA to be closed. Seed: ["claim_account",mint,refund_address].
    pub fn close_claim_account(ctx: Context<CloseClaimAccount>) -> Result<()> {
        instructions::close_claim_account(ctx)
    }

    // **************************************
    //            CCTP FUNCTIONS            *
    // *************************************

    /// Handles finalized cross-chain messages received from L1 Ethereum over CCTP V2.
    ///
    /// This function serves as the permissioned entry point for messages sent from the Ethereum mainnet to the Solana
    /// SVM Spoke program over CCTP V2. It processes the incoming message by translating it into a corresponding Solana
    /// instruction and then invokes the instruction within this program.
    ///
    /// The CCTP V2 Message Transmitter dispatches messages attested at Circle's finalized threshold (2000) to this
    /// instruction and anything below to `handle_receive_unfinalized_message`. This program intentionally does not
    /// implement the latter, so messages attested before the source chain reached hard finality can never be consumed.
    ///
    /// ### Required Accounts:
    /// - authority_pda: A signer account that ensures this instruction can only be called by the Message Transmitter.
    ///   This acts to block that only the CCTP V2 Message Transmitter can send messages to this program.
    ///   seed:["message_transmitter_authority", program_id]
    /// - state (Account): Spoke state PDA. Seed: ["state",state.seed] where seed is 0 on mainnet. Enforces that the
    ///   remote domain and sender are valid.
    /// - self_authority: An unchecked account used for authenticating self-CPI invoked by the received message.
    ///   seed: ["self_authority"].
    /// - program: The SVM Spoke program account.
    ///
    /// ### Parameters:
    /// - params: Contains information to process the received message, containing the following fields:
    ///     - remote_domain: The remote domain of the message sender.
    ///     - sender: The sender of the message.
    ///     - finality_threshold_executed: The finality threshold the message was attested at. Not checked here, as the
    ///       Message Transmitter dispatches only finalized messages to this instruction.
    ///     - message_body: The body of the message.
    ///     - authority_bump: The authority bump for the message transmitter.
    pub fn handle_receive_finalized_message<'info>(
        ctx: Context<'_, '_, '_, 'info, HandleReceiveFinalizedMessage<'info>>,
        params: HandleReceiveMessageParams,
    ) -> Result<()> {
        instructions::handle_receive_finalized_message(ctx, params)
    }

    /// Sets the current time for the SVM Spoke Pool when running in test mode. Disabled on Mainnet.
    pub fn set_current_time(ctx: Context<SetCurrentTime>, new_time: u32) -> Result<()> {
        utils::set_current_time(ctx, new_time)
    }
}
