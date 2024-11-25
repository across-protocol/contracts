use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked};

use crate::{
    common::V3RelayData,
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::{CommonError, SvmError},
    event::{FillType, FilledV3Relay, RequestedV3SlowFill, V3RelayExecutionEventInfo},
    state::{FillStatus, FillStatusAccount, RootBundle, State},
    utils::{get_current_time, hash_non_empty_message, invoke_handler, verify_merkle_proof},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct RequestV3SlowFill<'info> {
    /// Signer initiating the slow fill request.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// State account storing global configurations.
    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_fills @ CommonError::FillsArePaused
    )]
    pub state: Account<'info, State>,

    /// Fill status account tracking the status of the relay.
    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    /// System program for account initialization.
    pub system_program: Program<'info, System>,
}

/// Requests a slow fill for a relay.
///
/// ### Parameters:
/// - `ctx`: The context for the request.
/// - `relay_data`: The relay data.
pub fn request_v3_slow_fill(ctx: Context<RequestV3SlowFill>, relay_data: V3RelayData) -> Result<()> {
    let state = &ctx.accounts.state;
    let current_time = get_current_time(state)?;

    // Ensure the relay is outside the exclusivity window and within the fill deadline.
    if relay_data.exclusivity_deadline >= current_time {
        return err!(CommonError::NoSlowFillsInExclusivityWindow);
    }
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Validate the fill status is unfilled.
    let fill_status_account = &mut ctx.accounts.fill_status;
    if fill_status_account.status != FillStatus::Unfilled {
        return err!(CommonError::InvalidSlowFillRequest);
    }

    // Update the fill status to RequestedSlowFill.
    fill_status_account.status = FillStatus::RequestedSlowFill;
    fill_status_account.relayer = ctx.accounts.signer.key();

    let message_hash = hash_non_empty_message(&relay_data.message);
    emit_cpi!(RequestedV3SlowFill {
        input_token: relay_data.input_token,
        output_token: relay_data.output_token,
        input_amount: relay_data.input_amount,
        output_amount: relay_data.output_amount,
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message_hash,
    });

    Ok(())
}

/// Represents a V3 slow fill structure.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V3SlowFill {
    pub relay_data: V3RelayData,
    pub chain_id: u64,
    pub updated_output_amount: u64,
}

impl V3SlowFill {
    /// Serializes the slow fill data to bytes.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&[0u8; 64]); // Add padding to protect against cross-environment conflicts.
        AnchorSerialize::serialize(&self, &mut bytes)?;
        Ok(bytes)
    }

    /// Generates a Keccak hash of the serialized slow fill data.
    pub fn to_keccak_hash(&self) -> Result<[u8; 32]> {
        let input = self.to_bytes()?;
        Ok(keccak::hash(&input).to_bytes())
    }
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], slow_fill_leaf: V3SlowFill, root_bundle_id: u32)]
pub struct ExecuteV3SlowRelayLeaf<'info> {
    /// Signer initiating the execution.
    pub signer: Signer<'info>,

    /// State account storing global configurations.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Root bundle containing the Merkle root for slow fills.
    #[account(seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), root_bundle_id.to_le_bytes().as_ref()], bump)]
    pub root_bundle: Account<'info, RootBundle>,

    /// Fill status account tracking the relay's status.
    #[account(
        mut,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        constraint = is_relay_hash_valid(&relay_hash, &slow_fill_leaf.relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    /// Token mint for the output token.
    #[account(
        mint::token_program = token_program,
        address = slow_fill_leaf.relay_data.output_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    /// Recipient's token account for receiving the output tokens.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = slow_fill_leaf.relay_data.recipient,
        associated_token::token_program = token_program
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    /// Vault holding the output tokens for the relay.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// Token program for CPI interactions.
    pub token_program: Interface<'info, TokenInterface>,

    /// System program for additional operations.
    pub system_program: Program<'info, System>,
}

/// Executes a slow fill relay by transferring tokens and updating the fill status.
///
/// ### Parameters:
/// - `ctx`: The context for the execution.
/// - `slow_fill_leaf`: The slow fill leaf.
/// - `proof`: The Merkle proof for the relay data.
pub fn execute_v3_slow_relay_leaf<'info>(
    ctx: Context<'_, '_, '_, 'info, ExecuteV3SlowRelayLeaf<'info>>,
    slow_fill_leaf: V3SlowFill,
    proof: Vec<[u8; 32]>,
) -> Result<()> {
    let current_time = get_current_time(&ctx.accounts.state)?;

    let relay_data = slow_fill_leaf.relay_data;

    // Construct the slow fill with overridden chain_id for consistency.
    let slow_fill = V3SlowFill {
        relay_data: relay_data.clone(),
        chain_id: ctx.accounts.state.chain_id,
        updated_output_amount: slow_fill_leaf.updated_output_amount,
    };

    let root = ctx.accounts.root_bundle.slow_relay_root;
    let leaf = slow_fill.to_keccak_hash()?;
    verify_merkle_proof(root, leaf, proof)?;

    // Ensure the relay is within the fill deadline.
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Ensure the relay is not already filled.
    let fill_status_account = &mut ctx.accounts.fill_status;
    if fill_status_account.status == FillStatus::Filled {
        return err!(CommonError::RelayFilled);
    }

    // Prepare the token transfer context.
    let state_seed_bytes = ctx.accounts.state.seed.to_le_bytes();
    let seeds = &[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]];
    let signer_seeds = &[&seeds[..]];
    let transfer_accounts = TransferChecked {
        from: ctx.accounts.vault.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.state.to_account_info(),
    };
    let cpi_context = CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        transfer_accounts,
        signer_seeds,
    );
    transfer_checked(
        cpi_context,
        slow_fill_leaf.updated_output_amount,
        ctx.accounts.mint.decimals,
    )?;

    // Update the fill status to Filled.
    fill_status_account.status = FillStatus::Filled;

    // Invoke handler if a message is present.
    if relay_data.message.len() > 0 {
        invoke_handler(
            ctx.accounts.signer.as_ref(),
            ctx.remaining_accounts,
            &relay_data.message,
        )?;
    }

    let message_hash = hash_non_empty_message(&relay_data.message);
    emit_cpi!(FilledV3Relay {
        input_token: relay_data.input_token,
        output_token: relay_data.output_token,
        input_amount: relay_data.input_amount,
        output_amount: relay_data.output_amount,
        repayment_chain_id: 0,
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        relayer: Pubkey::default(),
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message_hash,
        relay_execution_info: V3RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message_hash: message_hash,
            updated_output_amount: slow_fill_leaf.updated_output_amount,
            fill_type: FillType::SlowFill,
        },
    });

    Ok(())
}
