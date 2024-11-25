use anchor_lang::prelude::*;

declare_id!("DnLjPzpMCW2CF99URhGF3jDYnVRcCJMjUWsbPb4xVoBn");

// External programs from idls directory (requires anchor run generateExternalTypes).
declare_program!(message_transmitter);
declare_program!(token_messenger_minter);

/// # Across SVM Spoke Program
///
/// Spoke pool implementation for Across Protocol enabling connection to the Solana Ecosystem. Program is functionally
/// the re-implementation of SpokePool.sol for Solana, with some extensions to be Solana compatible. The implementation
/// leverages Circle's CCTP for message and token bridging back and forth from Ethereum mainnet. As the EVM spoke pool,
/// this spoke pool is instructed by the EVM hubpool for pool rebalancing and relayer repayment.
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

use common::*;
use instructions::*;
use state::*;
use utils::*;

#[program]
pub mod svm_spoke {
    use super::*;

    /****************************************
     *            ADMIN FUNCTIONS           *
     ****************************************/

    /// Initializes the state for the SVM Spoke Pool. Only callable once.
    ///
    /// ### Accounts:
    /// - signer (Writable, Signer): The account that pays for the transaction and will own the state.
    /// - state (Writable): Spoke state PDA. Seed: ["state",seed] where seed is 0 on mainnet.
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
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the pause.
    /// - state (Writable): The Spoke state PDA. Seed: ["state", seed], where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - pause: `true` to pause the system, `false` to unpause it.
    pub fn pause_deposits(ctx: Context<PauseDeposits>, pause: bool) -> Result<()> {
        instructions::pause_deposits(ctx, pause)
    }

    /// Pauses the Spoke Pool from processing fills. Only callable by the owner.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the pause.
    /// - state (Writable): The Spoke state PDA. Seed: ["state", seed], where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - pause: `true` to pause the system, `false` to unpause it.
    pub fn pause_fills(ctx: Context<PauseFills>, pause: bool) -> Result<()> {
        instructions::pause_fills(ctx, pause)
    }

    /// Transfers ownership of the Spoke Pool. Only callable by the current owner.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the current owner to authorize the transfer.
    /// - state (Writable): The Spoke state PDA. Seed: ["state", seed] where `seed` is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - new_owner: The public key of the new owner.
    pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
        instructions::transfer_ownership(ctx, new_owner)
    }

    /// Enables or disables a route for deposits from an origin token to a destination chain ID. Callable only by the owner.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the route change.
    /// - payer (Signer): The account responsible for paying the transaction fees.
    /// - state (Writable): The Spoke state PDA. Seed: ["state", seed] where `seed` is 0 on mainnet.
    /// - route (Writable): PDA to store route information. Created on the first call, updated subsequently.
    ///   Seed: ["route", origin_token, state.seed, destination_chain_id].
    /// - vault (Writable): ATA to hold the origin token for the associated route. Created on the first call.
    ///   Authority must be set as the state, and mint must be the origin_token_mint.
    /// - origin_token_mint: The mint account for the origin token.
    /// - token_program: The token program.
    /// - associated_token_program: The associated token program.
    /// - system_program: The system program required for account creation.
    ///
    /// ### Parameters:
    /// - origin_token: The public key of the origin token.
    /// - destination_chain_id: The chain ID of the destination.
    /// - enabled: Boolean indicating whether the route is enabled or disabled.
    pub fn set_enable_route(
        ctx: Context<SetEnableRoute>,
        origin_token: Pubkey,
        destination_chain_id: u64,
        enabled: bool,
    ) -> Result<()> {
        instructions::set_enable_route(ctx, origin_token, destination_chain_id, enabled)
    }

    /// Sets the cross-domain admin for the Spoke Pool. Only callable by owner. Used if Hubpool upgrades.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the admin change.
    /// - state (Writable): Spoke state PDA. Seed: ["state",seed] where seed is 0 on mainnet.
    ///
    /// ### Parameters:
    /// - cross_domain_admin: The public key of the new cross-domain admin.
    pub fn set_cross_domain_admin(ctx: Context<SetCrossDomainAdmin>, cross_domain_admin: Pubkey) -> Result<()> {
        instructions::set_cross_domain_admin(ctx, cross_domain_admin)
    }

    /// Stores a new root bundle for later execution. Only callable by the owner.
    ///
    /// Once stored, these roots are used to execute relayer refunds, slow fills, and pool rebalancing actions.
    /// This method initializes a root_bundle PDA to store the root bundle data. The caller
    /// of this method is responsible for paying the rent for this PDA.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the addition of the new root bundle.
    /// - payer (Signer): The account responsible for paying the transaction fees and covering the rent for the root_bundle PDA.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The newly created bundle PDA to store root bundle data. Each root bundle has an
    ///   incrementing ID, stored in the state. Seed: ["root_bundle", state.seed,root_bundle_id].
    /// - system_program (Program): The system program required for account creation.
    ///
    /// ### Parameters:
    /// - relayer_refund_root: Merkle root of the relayer refund tree.
    /// - slow_relay_root: Merkle root of the slow relay tree.
    pub fn relay_root_bundle(
        ctx: Context<RelayRootBundle>,
        relayer_refund_root: [u8; 32],
        slow_relay_root: [u8; 32],
    ) -> Result<()> {
        instructions::relay_root_bundle(ctx, relayer_refund_root, slow_relay_root)
    }

    /// Deletes a root bundle in case of emergencies where a bad bundle has reached the Spoke. Only callable by owner.
    ///
    /// Will close the PDA for the associated root bundle_id. If used does not decrement state.root_bundle_id.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that must be the owner to authorize the deletion.
    /// - closer (SystemAccount): The account that will receive the lamports from closing the root_bundle account.
    /// - state (Writable): Spoke state PDA. Seed: ["state",seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The root bundle PDA to be closed. Seed: ["root_bundle", state.seed, root_bundle_id].
    ///
    /// ### Parameters:
    /// - root_bundle_id: Index of root bundle that needs to be deleted.
    pub fn emergency_delete_root_bundle(
        ctx: Context<EmergencyDeleteRootBundleState>,
        root_bundle_id: u32,
    ) -> Result<()> {
        instructions::emergency_delete_root_bundle(ctx, root_bundle_id)
    }

    /****************************************
     *          DEPOSIT FUNCTIONS           *
     ****************************************/

    /// Request to bridge input_token to a target chain and receive output_token.
    ///
    /// The fee paid to relayers and the system is captured in the spread between the input and output amounts,
    /// denominated in the input token. A relayer on the destination chain will send `output_amount` of `output_token`
    /// to the recipient and receive `input_token` on a repayment chain of their choice.
    ///
    /// The fee accounts for:
    /// - Destination transaction costs,
    /// - The relayer's opportunity cost of capital while waiting for a refund during the optimistic challenge window in the HubPool,
    /// - The system fee charged to the relayer.
    ///
    /// On the destination chain, a unique hash of the deposit data is used to identify this deposit. Modifying any
    /// parameters will result in a different hash, creating a separate deposit. The hash is computed using all parameters
    /// of this function along with the chain's `chainId()`. Relayers are refunded only for deposits with hashes that
    /// exactly match those emitted by this contract.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the deposit.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - route (Account): The route PDA for the particular bridged route in question. Validates a route is enabled.
    ///   Seed: ["route", input_token, state.seed, destination_chain_id].
    /// - depositor_token_account (Writable): The depositor's ATA for the input token.
    /// - vault (Writable): Programs ATA for the associated input token. This is where the depositor's assets are sent.
    ///   Authority must be the state.
    /// - mint (Account): The mint account for the input token.
    /// - token_program (Interface): The token program.
    ///
    /// ### Parameters
    /// - depositor: The account credited with the deposit. Can be different from the signer.
    /// - recipient: The account receiving funds on the destination chain. Depending on the output chain can be an ETH
    ///     address or a contract address or any other address type encoded as a bytes32 field.
    /// - input_token: The token pulled from the caller's account and locked into this program's vault on deposit.
    /// - output_token: The token that the relayer will send to the recipient on the destination chain.
    /// - input_amount: The amount of input tokens to pull from the caller's account and lock into the vault. This
    ///   amount will be sent to the relayer on their repayment chain of choice as a refund following an optimistic
    ///   challenge window in the HubPool, less a system fee.
    /// - output_amount: The amount of output tokens that the relayer will send to the recipient on the destination.
    /// - destination_chain_id: The destination chain identifier. Must be enabled along with the input token as a valid
    ///   deposit route from this spoke pool or this transaction will revert.
    /// - exclusive_relayer: The relayer that will be exclusively allowed to fill this deposit before the exclusivity deadline
    ///   timestamp. This must be a valid, non-zero address if the exclusivity deadline is greater than the current block
    ///   timestamp.
    /// - quote_timestamp: The HubPool timestamp that is used to determine the system fee paid by the depositor. This
    ///   must be set to some time between [currentTime - depositQuoteTimeBuffer, currentTime].
    /// - fill_deadline: The deadline for the relayer to fill the deposit. After this destination chain timestamp,
    ///   the fill will revert on the destination chain. Must be set between [currentTime, currentTime + fillDeadlineBuffer].
    /// - exclusivity_parameter: Sets the exclusivity deadline timestamp for the exclusiveRelayer to fill the deposit.
    ///   1. If 0, no exclusivity period.
    ///   2. If less than MAX_EXCLUSIVITY_PERIOD_SECONDS, adds this value to the current block timestamp.
    ///   3. Otherwise, uses this value as the exclusivity deadline timestamp.
    /// - message: The message to send to the recipient on the destination chain if the recipient is a contract.
    ///   If not empty, the recipient contract must implement handleV3AcrossMessage() or the fill will revert.
    pub fn deposit_v3(
        ctx: Context<DepositV3>,
        depositor: Pubkey,
        recipient: Pubkey,
        input_token: Pubkey,
        output_token: Pubkey,
        input_amount: u64,
        output_amount: u64,
        destination_chain_id: u64,
        exclusive_relayer: Pubkey,
        quote_timestamp: u32,
        fill_deadline: u32,
        exclusivity_parameter: u32,
        message: Vec<u8>,
    ) -> Result<()> {
        instructions::deposit_v3(
            ctx,
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
            message,
        )
    }

    // Equivalent to deposit_v3 except quote_timestamp is set to the current time.
    pub fn deposit_v3_now(
        ctx: Context<DepositV3>,
        depositor: Pubkey,
        recipient: Pubkey,
        input_token: Pubkey,
        output_token: Pubkey,
        input_amount: u64,
        output_amount: u64,
        destination_chain_id: u64,
        exclusive_relayer: Pubkey,
        fill_deadline: u32,
        exclusivity_parameter: u32,
        message: Vec<u8>,
    ) -> Result<()> {
        instructions::deposit_v3_now(
            ctx,
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            fill_deadline,
            exclusivity_parameter,
            message,
        )
    }

    /// Equivalent to deposit_v3 except the deposit_nonce is not used to derive the deposit_id for the depositor. This
    /// Lets the caller influence the deposit ID to make it deterministic for the depositor. The computed depositID is
    /// the keccak256 hash of [signer, depositor, deposit_nonce].
    pub fn unsafe_deposit_v3(
        ctx: Context<DepositV3>,
        depositor: Pubkey,
        recipient: Pubkey,
        input_token: Pubkey,
        output_token: Pubkey,
        input_amount: u64,
        output_amount: u64,
        destination_chain_id: u64,
        exclusive_relayer: Pubkey,
        deposit_nonce: u64,
        quote_timestamp: u32,
        fill_deadline: u32,
        exclusivity_parameter: u32,
        message: Vec<u8>,
    ) -> Result<()> {
        instructions::unsafe_deposit_v3(
            ctx,
            depositor,
            recipient,
            input_token,
            output_token,
            input_amount,
            output_amount,
            destination_chain_id,
            exclusive_relayer,
            deposit_nonce,
            quote_timestamp,
            fill_deadline,
            exclusivity_parameter,
            message,
        )
    }

    /// Computes the deposit ID for the depositor using the provided deposit_nonce. This acts like a "view" function for
    /// off-chain actors to compute what the expected deposit ID is for a given depositor and deposit nonce will be.
    ///
    /// ### Parameters:
    /// - signer: The public key of the depositor sender.
    /// - depositor: The public key of the depositor.
    /// - deposit_nonce: The nonce used to derive the deposit ID.
    pub fn get_unsafe_deposit_id(
        _ctx: Context<Null>,
        signer: Pubkey,
        depositor: Pubkey,
        deposit_nonce: u64,
    ) -> Result<[u8; 32]> {
        Ok(utils::get_unsafe_deposit_id(signer, depositor, deposit_nonce))
    }

    /****************************************
     *          RELAYER FUNCTIONS           *
     ****************************************/

    /// Fulfill request to bridge cross chain by sending specified output tokens to recipient.
    ///
    /// Relayer & system fee is captured in the spread between input and output amounts. This fee accounts for tx costs,
    /// relayer's capital opportunity cost, and a system fee. The relay_data hash uniquely identifies the deposit to
    /// fill, ensuring relayers are refunded only for deposits matching the original hash from the origin SpokePool.
    /// This hash includes all parameters from deposit_v3() and must match the destination_chain_id. Note the relayer
    /// creates a ATA in calling this method to store the fill_status. This should be closed once the deposit has
    /// expired to let the relayer re-claim their rent. Cannot fill more than once. Partial fills are not supported.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the fill (filler). No permission requirements.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - route (Account): The route PDA for the particular bridged route in question. Validates a route is enabled.
    ///   Seed: ["route", input_token, state.seed, destination_chain_id].
    /// - vault (Writable): The ATA for refunded mint. Authority must be the state.
    /// - mint (Account): The mint of the output token, send from the relayer to the recipient.
    /// - relayer_token_account (Writable): The relayer's ATA for the input token.
    /// - recipient_token_account (Writable): The recipient's ATA for the output token.
    /// - fill_status (Writable): The fill status PDA, created on this function call to track the fill status to prevent
    ///   re-entrancy & double fills. Also used to track requested slow fills. Seed: ["fills", relay_hash].
    /// - token_program (Interface): The token program.
    /// - associated_token_program (Interface): The associated token program.
    /// - system_program (Interface): The system program.
    ///
    /// ### Parameters:
    /// - _relay_hash: The hash identifying the deposit to to be filled. Caller must pass this in. Computed as hash of
    ///    the flattened relay_data & destination_chain_id.
    /// - relay_data: Struct containing all the data needed to identify the deposit to be filled. Should match
    ///   all the same-named parameters emitted in the origin chain V3FundsDeposited event.
    ///   - depositor: The account credited with the deposit.
    ///   - recipient: The account receiving funds on this chain.
    ///   - input_token: The token pulled from the caller's account to initiate the deposit. The equivalent of this
    ///     token on the repayment chain will be sent as a refund to the caller.
    ///   - output_token: The token that the caller will send to the recipient on the this chain.
    ///   - input_amount: This amount, less a system fee, will be sent to the caller on their repayment chain.
    ///   - output_amount: The amount of output tokens that the caller will send to the recipient.
    ///   - origin_chain_id: The origin chain identifier.
    ///   - exclusive_relayer: The relayer that will be exclusively allowed to fill this deposit before the
    ///     exclusivity deadline timestamp.
    ///   - fill_deadline: The deadline for the caller to fill the deposit. After this timestamp, the deposit will be
    ///     cancelled and the depositor will be refunded on the origin chain.
    ///   - exclusivity_deadline: The deadline for the exclusive relayer to fill the deposit. After this timestamp,
    ///     anyone can fill this deposit.
    ///   - message: The message to send to the recipient if the recipient is a contract that implements a
    ///     handle_v3_across_message() public function.
    /// - repayment_chain_id: Chain of SpokePool where relayer wants to be refunded after the challenge window has
    ///     passed. Will receive input_amount of the equivalent token to input_token on the repayment chain.
    /// - repayment_address: The address of the recipient on the repayment chain that they want to be refunded to.
    pub fn fill_v3_relay<'info>(
        ctx: Context<'_, '_, '_, 'info, FillV3Relay<'info>>,
        _relay_hash: [u8; 32],
        relay_data: V3RelayData,
        repayment_chain_id: u64,
        repayment_address: Pubkey,
    ) -> Result<()> {
        instructions::fill_v3_relay(ctx, relay_data, repayment_chain_id, repayment_address)
    }

    /// Closes the FillStatusAccount PDA to reclaim relayer rent.
    ///
    /// This function is used to close the FillStatusAccount associated with a specific relay hash, effectively marking
    /// the end of its lifecycle. This can only be done once the fill deadline has passed. Relayers should do this for
    /// all fills once they expire to reclaim their rent.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the closure. Must be the relayer in the fill_status PDA.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - fill_status (Writable): The FillStatusAccount PDA to be closed. Seed: ["fills", relay_hash].
    ///
    /// ### Parameters:
    /// - _relay_hash: The hash identifying the relay for which the fill status account is being closed.
    /// - relay_data: The data structure containing information about the relay.

    pub fn close_fill_pda(ctx: Context<CloseFillPda>, _relay_hash: [u8; 32], relay_data: V3RelayData) -> Result<()> {
        instructions::close_fill_pda(ctx, relay_data)
    }

    /// Claims a relayer refund for the caller.
    ///
    /// In the event a relayer refund was sent to a claim account, then this function enables the relayer to claim it by
    /// transferring the claim amount from the vault to their token account. The claim account is closed after refund.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the claim.
    /// - initializer (UncheckedAccount): Must be the same account that initialized the claim account.
    /// - state (Account): Spoke state PDA. Seed: ["state", state.seed] where seed is 0 on mainnet.
    /// - vault (InterfaceAccount): The ATA for the refunded mint. Authority must be the state.
    /// - mint (InterfaceAccount): The mint account for the token being refunded.
    /// - token_account (InterfaceAccount): The ATA for the token being refunded to.
    /// - claim_account (Account): The claim account PDA. Seed: ["claim_account", mint, refund_address].
    /// - token_program (Interface): The token program.
    pub fn claim_relayer_refund(ctx: Context<ClaimRelayerRefund>) -> Result<()> {
        instructions::claim_relayer_refund(ctx)
    }

    /// Functionally identical to claim_relayer_refund() except the refund is sent to a specified refund address.
    pub fn claim_relayer_refund_for(ctx: Context<ClaimRelayerRefundFor>, refund_address: Pubkey) -> Result<()> {
        instructions::claim_relayer_refund_for(ctx, refund_address)
    }

    /// Creates token accounts in batch for a set of addresses.
    ///
    /// This helper function allows the caller to pass in a set of remaining accounts to create a batch of Associated
    /// Token Accounts (ATAs) for addresses. It is particularly useful for relayers to call before filling a deposit.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the creation of token accounts.
    /// - mint (InterfaceAccount): The mint account for the token.
    /// - token_program (Interface): The token program.
    /// - associated_token_program (Program): The associated token program.
    /// - system_program (Program): The system program required for account creation.
    pub fn create_token_accounts<'info>(ctx: Context<'_, '_, '_, 'info, CreateTokenAccounts<'info>>) -> Result<()> {
        instructions::create_token_accounts(ctx)
    }

    /****************************************
     *           BUNDLE FUNCTIONS           *
     ****************************************/

    /// Executes relayer refund leaf. Only callable by owner.
    ///
    /// Processes a relayer refund leaf, verifying its inclusion in a previous Merkle root and that it was not
    /// previously executed. Function has two modes of operation: a) transfers all relayer refunds directly to
    /// relayers ATA or b) credits relayers with claimable claim_account PDA that they can use later to claim their
    /// refund. In the happy path, (a) should be used. (b) should only be used if there is a relayer within the bundle
    /// who can't receive the transfer for some reason, such as failed token transfers due to blacklisting. Executing
    /// relayer refunds requires the caller to create a LUT and load the execution params into it. This is needed to
    /// fit the data in a single instruction. The exact structure and validation of the leaf is defined in the UMIP.
    ///
    /// instruction_params Parameters:
    /// - root_bundle_id: The ID of the root bundle containing the relayer refund root.
    /// - relayer_refund_leaf: The relayer refund leaf to be executed. Contents must include:
    ///     - amount_to_return: The amount to be to be sent back to mainnet Ethereum from this Spoke pool.
    ///     - chain_id: The targeted chainId for the refund. Validated against state.chain_id.
    ///     - refund_amounts: The amounts to be returned to the relayer for each refund_address.
    ///     - leaf_id: The leaf ID of the relayer refund leaf.
    ///     - mint_public_key: The public key of the mint (refunded token) being refunded.
    ///     - refund_addresses: The addresses to be refunded.
    /// - proof: The Merkle proof for the relayer refund leaf.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the execution. No permission requirements.
    /// - instruction_params (Account): LUT containing the execution parameters. seed: ["instruction_params", signer]
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - root_bundle (Writable): The root bundle PDA containing the relayer refund root, created when the root bundle
    ///   was initially bridged. seed: ["root_bundle", state.seed, root_bundle_id].
    /// - vault (Writable): The ATA for refunded mint. Authority must be the state.
    /// - mint (Account): The mint account for the token being refunded.
    /// - transfer_liability (Writable): Account to track pending refunds to be sent to the Ethereum hub pool. Only used
    ///   if the amount_to_return value is non-zero within the leaf. Seed: ["transfer_liability",mint]
    /// - token_program: The token program.
    /// - system_program: The system program required for account creation.
    ///
    /// execute_relayer_refund_leaf executes in mode (a) where refunds are sent to ATA directly.
    /// execute_relayer_refund_leaf_deferred executes in mode (b) where refunds are allocated to the claim_account PDA.
    pub fn execute_relayer_refund_leaf<'c, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    ) -> Result<()>
    where
        'c: 'info,
    {
        instructions::execute_relayer_refund_leaf(ctx, false)
    }

    pub fn execute_relayer_refund_leaf_deferred<'c, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    ) -> Result<()>
    where
        'c: 'info,
    {
        instructions::execute_relayer_refund_leaf(ctx, true)
    }

    /// Bridges tokens to the Hub Pool.
    ///
    /// This function initiates the process of sending tokens from the vault to the Hub Pool based on the outstanding
    /// token liability this Spoke Pool has accrued. Enables the caller to choose a custom amount to work around CCTP
    /// bridging limits. enforces that amount is less than or equal to liability. On execution decrements liability.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the bridge operation.
    /// - payer (Signer): The account responsible for paying the transaction fees.
    /// - mint (InterfaceAccount): The mint account for the token being bridged.
    /// - state (Account): Spoke state PDA. Seed: ["state", state.seed] where seed is 0 on mainnet.
    /// - transfer_liability (Account): Account tracking the pending amount to be sent to the Hub Pool. Incremented on
    ///   relayRootBundle() and decremented on when this function is called. Seed: ["transfer_liability", mint].
    /// - vault (InterfaceAccount): The ATA for the token being bridged. Authority must be the state.
    /// - token_messenger_minter_sender_authority (UncheckedAccount): Authority for the token messenger minter.
    /// - message_transmitter (UncheckedAccount): Account for the message transmitter.
    /// - token_messenger (UncheckedAccount): Account for the token messenger.
    /// - remote_token_messenger (UncheckedAccount): Account for the remote token messenger.
    /// - token_minter (UncheckedAccount): Account for the token minter.
    /// - local_token (UncheckedAccount): Account for the local token.
    /// - cctp_event_authority (UncheckedAccount): Authority for CCTP events.
    /// - message_sent_event_data (Signer): Account for message sent event data.
    /// - message_transmitter_program (Program): Program for the message transmitter.
    /// - token_messenger_minter_program (Program): Program for the token messenger minter.
    /// - token_program (Interface): The token program.
    /// - system_program (Program): The system program.
    ///
    /// ### Parameters:
    /// - amount: The amount of tokens to bridge to the Hub Pool.
    pub fn bridge_tokens_to_hub_pool(ctx: Context<BridgeTokensToHubPool>, amount: u64) -> Result<()> {
        instructions::bridge_tokens_to_hub_pool(ctx, amount)?;
        Ok(())
    }

    /// Initializes the instruction parameters account. Used by data worker when relaying bundles
    ///
    /// This function sets up an account to store raw data fragments for instructions (LUT).
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that pays for the transaction and initializes the instruction parameters.
    /// - instruction_params (UncheckedAccount): The account where raw data will be stored. Initialized with specified
    ///   size. seed: ["instruction_params", signer].
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
    /// ### Accounts:
    /// - signer (Signer): Account that authorizes the write operation.
    /// - instruction_params (UncheckedAccount): Account to write raw data to. seed: ["instruction_params", signer].
    /// - system_program: The system program required for account operations.
    ///
    /// ### Parameters:
    /// - offset: The starting position within the account's data where the fragment will be written.
    /// - fragment: The raw data fragment to be written into the account.
    pub fn write_instruction_params_fragment<'info>(
        ctx: Context<WriteInstructionParamsFragment<'info>>,
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
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the closure.
    /// - instruction_params (UncheckedAccount): The account to be closed. seed: ["instruction_params", signer]. Not
    ///   the signer being within the seed here implicitly protects this from only being called by the creator.
    pub fn close_instruction_params(ctx: Context<CloseInstructionParams>) -> Result<()> {
        instructions::close_instruction_params(ctx)
    }

    /// Initializes a claim account for a relayer refund.
    ///
    /// This function sets up a claim account for a relayer to claim their refund at a later time and should only be
    /// used in the un-happy path where a bundle cant not be executed due to a recipient in the bundle having a blocked
    /// or uninitialized claim ATA. the refund address, ass passed into this function, becomes the "owner" of the claim_account.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that pays for the transaction and initializes the claim account.
    /// - claim_account (Writable): The newly created claim account PDA to store claim data for this associated mint.
    ///   Seed: ["claim_account", mint, refund_address].
    /// - system_program: The system program required for account creation.
    ///
    /// ### Parameters:
    /// - _mint: The public key of the mint associated with the claim account.
    /// - _refund_address: The public key of the refund address associated with the claim account.
    pub fn initialize_claim_account(
        ctx: Context<InitializeClaimAccount>,
        _mint: Pubkey,
        _refund_address: Pubkey,
    ) -> Result<()> {
        instructions::initialize_claim_account(ctx)
    }

    /// Closes a claim account for a relayer refund.
    ///
    /// This function is used to close the claim account associated with a specific mint and refund address,
    /// effectively marking the end of its lifecycle. It can only be called once the claim account is empty. It
    /// transfers any remaining lamports to the signer and resets the account.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the closure. Must be the initializer of the claim account.
    /// - claim_account (Writable): The claim account PDA to be closed. Seed: ["claim_account", mint, refund_address].
    ///
    /// ### Parameters:
    /// - _mint: The public key of the mint associated with the claim account.
    /// - _refund_address: The public key of the refund address associated with the claim account.
    pub fn close_claim_account(
        ctx: Context<CloseClaimAccount>,
        _mint: Pubkey,           // Only used in account constraints.
        _refund_address: Pubkey, // Only used in account constraints.
    ) -> Result<()> {
        instructions::close_claim_account(ctx)
    }

    /****************************************
     *         SLOW FILL FUNCTIONS          *
     ****************************************/

    /// Requests Across to send LP funds to this program to fulfill a slow fill.
    ///
    /// Slow fills are not possible unless the input and output tokens are "equivalent", i.e., they route to the same L1
    /// token via PoolRebalanceRoutes. Slow fills are created by inserting slow fill objects into a Merkle tree that is
    /// included in the next HubPool "root bundle". Once the optimistic challenge window has passed, the HubPool will
    /// relay the slow root to this chain via relayRootBundle(). Once the slow root is relayed, the slow fill can be
    /// executed by anyone who calls executeV3SlowRelayLeaf(). Cant request a slow fill if the fill deadline has
    /// passed. Cant request a slow fill if the relay has already been filled or a slow fill has already been requested.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the slow fill request.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - fill_status (Writable): The fill status PDA, created on this function call. Updated to track slow fill status.
    ///   Used to prevent double request and fill. Seed: ["fills", relay_hash].
    /// - system_program (Interface): The system program.
    ///
    /// ### Parameters:
    /// - _relay_hash: The hash identifying the deposit to be filled. Caller must pass this in. Computed as hash of
    ///   the flattened relay_data & destination_chain_id.
    /// - relay_data: Struct containing all the data needed to identify the deposit that should be slow filled. If any
    ///   of the params are missing or different from the origin chain deposit, then Across will not include a slow
    ///   fill for the intended deposit. See fill_v3_relay & V3RelayData struct for more details.
    pub fn request_v3_slow_fill(
        ctx: Context<RequestV3SlowFill>,
        _relay_hash: [u8; 32],
        relay_data: V3RelayData,
    ) -> Result<()> {
        instructions::request_v3_slow_fill(ctx, relay_data)
    }

    /// Executes a slow relay leaf stored as part of a root bundle relayed by the HubPool.
    ///
    /// Executing a slow fill leaf is equivalent to filling the relayData, so this function cannot be used to
    /// double fill a recipient. The relayData that is filled is included in the slowFillLeaf and is hashed
    /// like any other fill sent through fillV3Relay(). There is no relayer credited with filling this relay since funds
    /// are sent directly out of this program's vault.
    ///
    /// ### Accounts:
    /// - signer (Signer): The account that authorizes the execution. No permission requirements.
    /// - state (Writable): Spoke state PDA. Seed: ["state", seed] where seed is 0 on mainnet.
    /// - root_bundle (Account): Root bundle PDA with slowRelayRoot. Seed: ["root_bundle",state.seed,root_bundle_id].
    /// - fill_status (Writable): The fill status PDA, created when slow request was made. Updated to track slow fill.
    ///   Used to prevent double request and fill. Seed: ["fills", relay_hash].
    /// - mint (Account): The mint account for the output token.
    /// - recipient_token_account (Writable): The recipient's ATA for the output token.
    /// - vault (Writable): The ATA for refunded mint. Authority must be the state.
    /// - token_program (Interface): The token program.
    /// - system_program (Program): The system program.
    ///
    /// ### Parameters:
    /// - _relay_hash: The hash identifying the deposit to be filled. Used to identify the deposit to be filled.
    /// - slow_fill_leaf: Contains all data necessary to uniquely verify the slow fill. This struct contains:
    ///     - relayData: Struct containing all the data needed to identify the original deposit to be slow filled. Same
    ///       as the relay_data struct in fill_v3_relay().
    ///     - chainId: Chain identifier where slow fill leaf should be executed. If this doesn't match this chain's
    ///       chainId, then this function will revert.
    ///     - updatedOutputAmount: Amount to be sent to recipient out of this contract's balance. Can be set differently
    ///       from relayData.outputAmount to charge a different fee because this deposit was "slow" filled. Usually,
    ///       this will be set higher to reimburse the recipient for waiting for the slow fill.
    /// - _root_bundle_id: Unique ID of root bundle containing slow relay root that this leaf is contained in.
    /// - proof: Inclusion proof for this leaf in slow relay root in root bundle.
    pub fn execute_v3_slow_relay_leaf<'info>(
        ctx: Context<'_, '_, '_, 'info, ExecuteV3SlowRelayLeaf<'info>>,
        _relay_hash: [u8; 32],
        slow_fill_leaf: V3SlowFill,
        _root_bundle_id: u32,
        proof: Vec<[u8; 32]>,
    ) -> Result<()> {
        instructions::execute_v3_slow_relay_leaf(ctx, slow_fill_leaf, proof)
    }

    /****************************************
     *       CCTP FUNCTIONS FUNCTIONS       *
     ****************************************/

    /// Handles cross-chain messages received from L1 Ethereum over CCTP.
    ///
    /// This function serves as the permissioned entry point for messages sent from the Ethereum mainnet to the Solana
    /// SVM Spoke program over CCTP. It processes the incoming message by translating it into a corresponding Solana
    /// instruction and then invokes the instruction within this program.
    ///
    /// ### Accounts:
    /// - authority_pda: A signer account that ensures this instruction can only be called by the Message Transmitter.
    ///   This acts to block that only the CCTP Message Transmitter can send messages to this program.
    ///   seed:["message_transmitter_authority", program_id]
    /// - state (Account): Spoke state PDA. Seed: ["state", state.seed] where seed is 0 on mainnet. Enforces that the
    ///   remote domain and sender are valid.
    /// - self_authority: An unchecked account used for authenticating self-CPI invoked by the received message.
    ///   seed: ["self_authority"].
    /// - program: The SVM Spoke program account.
    ///
    /// ### Parameters:
    /// - params: Contains information to process the received message, containing the following fields:
    ///     - remote_domain: The remote domain of the message sender.
    ///     - sender: The sender of the message.
    ///     - message_body: The body of the message.
    ///     - authority_bump: The authority bump for the message transmitter.
    pub fn handle_receive_message<'info>(
        ctx: Context<'_, '_, '_, 'info, HandleReceiveMessage<'info>>,
        params: HandleReceiveMessageParams,
    ) -> Result<()> {
        instructions::handle_receive_message(ctx, params)
    }

    /// Sets the current time for the SVM Spoke Pool when running in test mode. Disabled on Mainnet.
    pub fn set_current_time(ctx: Context<SetCurrentTime>, new_time: u32) -> Result<()> {
        utils::set_current_time(ctx, new_time)
    }
}
