use anchor_lang::prelude::*;

declare_id!("Fdedr2RqfufUiE1sbVEfpSQ3NADJqxrvu1zojWpQJj4q");

// External programs from idls directory (requires `anchor run generateExternalTypes`).
declare_program!(message_transmitter);
declare_program!(token_messenger_minter);

pub mod constants;
mod constraints;
pub mod error;
pub mod event;
mod instructions;
mod state;
pub mod utils;

use instructions::*;
use state::*;

#[program]
pub mod svm_spoke {
    use super::*;

    // Admin methods.
    pub fn initialize(
        ctx: Context<Initialize>,
        seed: u64,
        initial_number_of_deposits: u32,
        chain_id: u64,
        remote_domain: u32,
        cross_domain_admin: Pubkey,
        deposit_quote_time_buffer: u32,
        fill_deadline_buffer: u32
    ) -> Result<()> {
        instructions::initialize(
            ctx,
            seed,
            initial_number_of_deposits,
            chain_id,
            remote_domain,
            cross_domain_admin,
            deposit_quote_time_buffer,
            fill_deadline_buffer
        )
    }

    pub fn set_current_time(ctx: Context<SetCurrentTime>, new_time: u32) -> Result<()> {
        instructions::set_current_time(ctx, new_time)
    }

    pub fn pause_deposits(ctx: Context<PauseDeposits>, pause: bool) -> Result<()> {
        instructions::pause_deposits(ctx, pause)
    }

    pub fn relay_root_bundle(
        ctx: Context<RelayRootBundle>,
        relayer_refund_root: [u8; 32],
        slow_relay_root: [u8; 32]
    ) -> Result<()> {
        instructions::relay_root_bundle(ctx, relayer_refund_root, slow_relay_root)
    }

    pub fn emergency_delete_root_bundle(
        ctx: Context<EmergencyDeleteRootBundleState>,
        root_bundle_id: u32
    ) -> Result<()> {
        instructions::emergency_delete_root_bundle(ctx, root_bundle_id)
    }

    pub fn execute_relayer_refund_leaf<'c, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>
    ) -> Result<()>
        where 'c: 'info
    {
        instructions::execute_relayer_refund_leaf(ctx)
    }

    pub fn pause_fills(ctx: Context<PauseFills>, pause: bool) -> Result<()> {
        instructions::pause_fills(ctx, pause)
    }

    pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
        instructions::transfer_ownership(ctx, new_owner)
    }

    pub fn set_enable_route(
        ctx: Context<SetEnableRoute>,
        origin_token: Pubkey,
        destination_chain_id: u64,
        enabled: bool
    ) -> Result<()> {
        instructions::set_enable_route(ctx, origin_token, destination_chain_id, enabled)
    }

    pub fn set_cross_domain_admin(ctx: Context<SetCrossDomainAdmin>, cross_domain_admin: Pubkey) -> Result<()> {
        instructions::set_cross_domain_admin(ctx, cross_domain_admin)
    }

    // User methods.
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
        exclusivity_deadline: u32,
        message: Vec<u8>
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
            exclusivity_deadline,
            message
        )
    }

    // Relayer methods.
    pub fn fill_v3_relay(
        ctx: Context<FillV3Relay>,
        relay_hash: [u8; 32],
        relay_data: V3RelayData,
        repayment_chain_id: u64,
        repayment_address: Pubkey
    ) -> Result<()> {
        instructions::fill_v3_relay(ctx, relay_hash, relay_data, repayment_chain_id, repayment_address)
    }

    pub fn close_fill_pda(ctx: Context<CloseFillPda>, relay_hash: [u8; 32], relay_data: V3RelayData) -> Result<()> {
        instructions::close_fill_pda(ctx, relay_hash, relay_data)
    }

    // CCTP methods.
    pub fn handle_receive_message<'info>(
        ctx: Context<'_, '_, '_, 'info, HandleReceiveMessage<'info>>,
        params: HandleReceiveMessageParams
    ) -> Result<()> {
        let self_ix_data = ctx.accounts.handle_receive_message(&params)?;

        invoke_self(&ctx, &self_ix_data)?;

        Ok(())
    }

    // Slow fill methods.
    pub fn request_v3_slow_fill(
        ctx: Context<SlowFillV3Relay>,
        relay_hash: [u8; 32],
        relay_data: V3RelayData
    ) -> Result<()> {
        instructions::request_v3_slow_fill(ctx, relay_hash, relay_data)
    }

    pub fn execute_v3_slow_relay_leaf(
        ctx: Context<ExecuteV3SlowRelayLeaf>,
        relay_hash: [u8; 32],
        slow_fill_leaf: V3SlowFill,
        root_bundle_id: u32,
        proof: Vec<[u8; 32]>
    ) -> Result<()> {
        instructions::execute_v3_slow_relay_leaf(ctx, relay_hash, slow_fill_leaf, root_bundle_id, proof)
    }
    pub fn bridge_tokens_to_hub_pool(ctx: Context<BridgeTokensToHubPool>, amount: u64) -> Result<()> {
        instructions::bridge_tokens_to_hub_pool(ctx, amount)?;

        Ok(())
    }

    pub fn initialize_instruction_params(_ctx: Context<InitializeInstructionParams>, _: u32) -> Result<()> {
        Ok(())
    }

    pub fn write_instruction_params_fragment<'info>(
        ctx: Context<WriteInstructionParamsFragment<'info>>,
        offset: u32,
        fragment: Vec<u8>
    ) -> Result<()> {
        instructions::write_instruction_params_fragment(ctx, offset, fragment)
    }

    pub fn close_instruction_params(ctx: Context<CloseInstructionParams>) -> Result<()> {
        instructions::close_instruction_params(ctx)
    }

    pub fn initialize_claim_account(
        ctx: Context<InitializeClaimAccount>,
        mint: Pubkey,
        token_account: Pubkey
    ) -> Result<()> {
        instructions::initialize_claim_account(ctx, mint, token_account)
    }

    pub fn claim_relayer_refund(ctx: Context<ClaimRelayerRefund>) -> Result<()> {
        instructions::claim_relayer_refund(ctx)
    }

    pub fn close_claim_account(
        ctx: Context<CloseClaimAccount>,
        _mint: Pubkey, // Only used in account constraints.
        _token_account: Pubkey // Only used in account constraints.
    ) -> Result<()> {
        instructions::close_claim_account(ctx)
    }
}
