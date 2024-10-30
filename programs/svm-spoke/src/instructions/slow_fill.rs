use anchor_lang::{ prelude::*, solana_program::keccak };
use anchor_spl::token_interface::{ transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked };

use crate::{
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::{ CommonError, SvmError },
    get_current_time,
    state::{ FillStatus, FillStatusAccount, RootBundle, State },
    common::V3RelayData,
    utils::verify_merkle_proof,
};

use crate::event::{ FillType, FilledV3Relay, RequestedV3SlowFill, V3RelayExecutionEventInfo };

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct SlowFillV3Relay<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_fills @ CommonError::FillsArePaused
    )]
    pub state: Account<'info, State>,

    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        // Make sure caller provided relay_hash used in PDA seeds is valid.
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,
    pub system_program: Program<'info, System>,
}

pub fn request_v3_slow_fill(ctx: Context<SlowFillV3Relay>, relay_data: V3RelayData) -> Result<()> {
    let state = &ctx.accounts.state;

    let current_time = get_current_time(state)?;

    // Check if the fill is past the exclusivity window & within the fill deadline.
    if relay_data.exclusivity_deadline >= current_time {
        return err!(CommonError::NoSlowFillsInExclusivityWindow);
    }
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Check the fill status
    let fill_status_account = &mut ctx.accounts.fill_status;
    if fill_status_account.status != FillStatus::Unfilled {
        return err!(CommonError::InvalidSlowFillRequest);
    }

    // Update the fill status to RequestedSlowFill
    fill_status_account.status = FillStatus::RequestedSlowFill;
    fill_status_account.relayer = ctx.accounts.signer.key();

    // Emit the RequestedV3SlowFill event
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
        message: relay_data.message,
    });

    Ok(())
}

// Define the V3SlowFill struct
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V3SlowFill {
    pub relay_data: V3RelayData,
    pub chain_id: u64,
    pub updated_output_amount: u64,
}

impl V3SlowFill {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();

        // Order should match the Solidity struct field order
        bytes.extend_from_slice(&self.relay_data.depositor.to_bytes());
        bytes.extend_from_slice(&self.relay_data.recipient.to_bytes());
        bytes.extend_from_slice(&self.relay_data.exclusive_relayer.to_bytes());
        bytes.extend_from_slice(&self.relay_data.input_token.to_bytes());
        bytes.extend_from_slice(&self.relay_data.output_token.to_bytes());
        bytes.extend_from_slice(&self.relay_data.input_amount.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.output_amount.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.origin_chain_id.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.deposit_id.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.fill_deadline.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.exclusivity_deadline.to_le_bytes());
        bytes.extend_from_slice(&self.relay_data.message);
        bytes.extend_from_slice(&self.chain_id.to_le_bytes());
        bytes.extend_from_slice(&self.updated_output_amount.to_le_bytes());

        bytes
    }

    pub fn to_keccak_hash(&self) -> [u8; 32] {
        let input = self.to_bytes();
        keccak::hash(&input).0
    }
}

// Define the V3SlowFill struct
#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], slow_fill_leaf: V3SlowFill, root_bundle_id: u32)]
pub struct ExecuteV3SlowRelayLeaf<'info> {
    pub signer: Signer<'info>,
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(seeds = [b"root_bundle", state.key().as_ref(), root_bundle_id.to_le_bytes().as_ref()], bump)]
    pub root_bundle: Account<'info, RootBundle>,

    #[account(
        mut,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        // Make sure caller provided relay_hash used in PDA seeds is valid.
        constraint = is_relay_hash_valid(&relay_hash, &slow_fill_leaf.relay_data, &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    #[account(
        mint::token_program = token_program,
        address = slow_fill_leaf.relay_data.output_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = slow_fill_leaf.relay_data.recipient,
        associated_token::token_program = token_program
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn execute_v3_slow_relay_leaf(
    ctx: Context<ExecuteV3SlowRelayLeaf>,
    slow_fill_leaf: V3SlowFill,
    proof: Vec<[u8; 32]>
) -> Result<()> {
    let current_time = get_current_time(&ctx.accounts.state)?;

    let relay_data = slow_fill_leaf.relay_data;

    let slow_fill = V3SlowFill {
        relay_data: relay_data.clone(), // Clone relay_data to avoid move
        chain_id: ctx.accounts.state.chain_id, // This overrides caller provided chain_id, same as in EVM SpokePool.
        updated_output_amount: slow_fill_leaf.updated_output_amount,
    };

    let root = ctx.accounts.root_bundle.slow_relay_root;
    let leaf = slow_fill.to_keccak_hash();
    verify_merkle_proof(root, leaf, proof)?;

    // Check if the fill deadline has passed
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Check if the fill status is not filled
    let fill_status_account = &mut ctx.accounts.fill_status;
    if fill_status_account.status == FillStatus::Filled {
        return err!(CommonError::RelayFilled);
    }

    // Derive the signer seeds for the state
    let state_seed_bytes = ctx.accounts.state.seed.to_le_bytes();
    let seeds = &[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]];
    let signer_seeds = &[&seeds[..]];

    // Invoke the transfer_checked instruction on the token program
    let transfer_accounts = TransferChecked {
        from: ctx.accounts.vault.to_account_info(), // Pull from the vault
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(), // Send to the recipient
        authority: ctx.accounts.state.to_account_info(), // Authority is the state (owner of the vault)
    };
    let cpi_context = CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        transfer_accounts,
        signer_seeds
    );
    transfer_checked(cpi_context, slow_fill_leaf.updated_output_amount, ctx.accounts.mint.decimals)?;

    // Update the fill status to Filled. Note we don't set the relayer here as it is set when the slow fill was requested.
    fill_status_account.status = FillStatus::Filled;

    // Emit the FilledV3Relay event
    let message_clone = relay_data.message.clone(); // Clone the message before it is moved

    emit_cpi!(FilledV3Relay {
        input_token: relay_data.input_token,
        output_token: relay_data.output_token,
        input_amount: relay_data.input_amount,
        output_amount: relay_data.output_amount,
        repayment_chain_id: 0, // There is no repayment chain id for slow fills.
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        relayer: Pubkey::default(), // There is no repayment address for slow
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message: relay_data.message,
        relay_execution_info: V3RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message: message_clone,
            updated_output_amount: slow_fill_leaf.updated_output_amount,
            fill_type: FillType::SlowFill,
        },
    });

    Ok(())
}
