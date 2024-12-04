use anchor_lang::{ prelude::*, solana_program::keccak };
use anchor_spl::token_interface::{ transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked };

use crate::event::{ FillType, FilledV3Relay, RequestedV3SlowFill, V3RelayExecutionEventInfo };
use crate::{
    common::V3RelayData,
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::{ CommonError, SvmError },
    state::{ ExecuteV3SlowRelayLeafParams, FillStatus, FillStatusAccount, RequestV3SlowFillParams, RootBundle, State },
    utils::{ get_current_time, hash_non_empty_message, invoke_handler, verify_merkle_proof },
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: Option<V3RelayData>)]
pub struct RequestV3SlowFill<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    // This is required as fallback when None instruction params are passed in arguments.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump, close = signer)]
    pub instruction_params: Option<Account<'info, RequestV3SlowFillParams>>,

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
        constraint = is_relay_hash_valid(
            &relay_hash,
            &relay_data.clone().unwrap_or_else(|| instruction_params.as_ref().unwrap().relay_data.clone()),
            &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,
    pub system_program: Program<'info, System>,
}

pub fn request_v3_slow_fill(ctx: Context<RequestV3SlowFill>, relay_data: Option<V3RelayData>) -> Result<()> {
    let RequestV3SlowFillParams { relay_data } = unwrap_request_v3_slow_fill_params(
        relay_data,
        &ctx.accounts.instruction_params
    );

    let state = &ctx.accounts.state;

    let current_time = get_current_time(state)?;

    // Check if the fill is past the exclusivity window & within the fill deadline.
    if relay_data.exclusivity_deadline >= current_time {
        return err!(CommonError::NoSlowFillsInExclusivityWindow);
    }
    if relay_data.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Check the fill status is unfilled.
    let fill_status_account = &mut ctx.accounts.fill_status;
    if fill_status_account.status != FillStatus::Unfilled {
        return err!(CommonError::InvalidSlowFillRequest);
    }

    fill_status_account.status = FillStatus::RequestedSlowFill; // Update the fill status to RequestedSlowFill
    fill_status_account.relayer = ctx.accounts.signer.key();
    fill_status_account.fill_deadline = relay_data.fill_deadline;

    // Emit the RequestedV3SlowFill event. Empty message is not hashed and emits zeroed bytes32 for easier observability
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

// Helper to unwrap optional instruction params with fallback loading from buffer account.
fn unwrap_request_v3_slow_fill_params(
    relay_data: Option<V3RelayData>,
    account: &Option<Account<RequestV3SlowFillParams>>
) -> RequestV3SlowFillParams {
    match relay_data {
        Some(relay_data) => RequestV3SlowFillParams { relay_data },
        _ =>
            account
                .as_ref()
                .map(|account| RequestV3SlowFillParams { relay_data: account.relay_data.clone() })
                .unwrap(), // We do not expect this to panic here as missing instruction_params is unwrapped in context.
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct V3SlowFill {
    pub relay_data: V3RelayData,
    pub chain_id: u64,
    pub updated_output_amount: u64,
}

impl V3SlowFill {
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();

        // This requires the first 64 bytes to be 0 within the encoded leaf data. This protects any kind of EVM leaf
        // from ever being used on SVM (and vice versa). This covers the deposit and recipient fields.
        bytes.extend_from_slice(&[0u8; 64]);

        AnchorSerialize::serialize(&self, &mut bytes)?;

        Ok(bytes)
    }

    pub fn to_keccak_hash(&self) -> Result<[u8; 32]> {
        let input = self.to_bytes()?;
        Ok(keccak::hash(&input).to_bytes())
    }
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], slow_fill_leaf: Option<V3SlowFill>, root_bundle_id: Option<u32>)]
pub struct ExecuteV3SlowRelayLeaf<'info> {
    pub signer: Signer<'info>,

    // This is required as fallback when None instruction params are passed in arguments.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump, close = signer)]
    pub instruction_params: Option<Account<'info, ExecuteV3SlowRelayLeafParams>>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        seeds = [
            b"root_bundle",
            state.seed.to_le_bytes().as_ref(),
            root_bundle_id
                .unwrap_or_else(|| instruction_params.as_ref().unwrap().root_bundle_id)
                .to_le_bytes()
                .as_ref(),
        ],
        bump
    )]
    pub root_bundle: Account<'info, RootBundle>,

    #[account(
        mut,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        // Make sure caller provided relay_hash used in PDA seeds is valid.
        constraint = is_relay_hash_valid(
            &relay_hash,
            &slow_fill_leaf
                .clone()
                .unwrap_or_else(|| instruction_params.as_ref().unwrap().slow_fill_leaf.clone())
                .relay_data,
            &state) @ SvmError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    #[account(
        mint::token_program = token_program,
        address = slow_fill_leaf
            .clone()
            .unwrap_or_else(|| instruction_params.as_ref().unwrap().slow_fill_leaf.clone())
            .relay_data
            .output_token @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = slow_fill_leaf
            .clone()
            .unwrap_or_else(|| instruction_params.as_ref().unwrap().slow_fill_leaf.clone())
            .relay_data
            .recipient,
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

pub fn execute_v3_slow_relay_leaf<'info>(
    ctx: Context<'_, '_, '_, 'info, ExecuteV3SlowRelayLeaf<'info>>,
    slow_fill_leaf: Option<V3SlowFill>,
    proof: Option<Vec<[u8; 32]>>
) -> Result<()> {
    let ExecuteV3SlowRelayLeafParams { slow_fill_leaf, proof, .. } = unwrap_execute_v3_slow_relay_leaf_params(
        slow_fill_leaf,
        proof,
        &ctx.accounts.instruction_params
    );

    let current_time = get_current_time(&ctx.accounts.state)?;

    let relay_data = slow_fill_leaf.relay_data;

    let slow_fill = V3SlowFill {
        relay_data: relay_data.clone(), // Clone relay_data to avoid move
        chain_id: ctx.accounts.state.chain_id, // This overrides caller provided chain_id, same as in EVM SpokePool.
        updated_output_amount: slow_fill_leaf.updated_output_amount,
    };

    let root = ctx.accounts.root_bundle.slow_relay_root;
    let leaf = slow_fill.to_keccak_hash()?;
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

    // Update the fill status. We don't set the relayer and fill deadline as it is set when the slow fill was requested.
    fill_status_account.status = FillStatus::Filled;

    if !relay_data.message.is_empty() {
        invoke_handler(ctx.accounts.signer.as_ref(), ctx.remaining_accounts, &relay_data.message)?;
    }

    // Empty message is not hashed and emits zeroed bytes32 for easier human observability.
    let message_hash = hash_non_empty_message(&relay_data.message);

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

// Helper to unwrap optional instruction params with fallback loading from buffer account.
fn unwrap_execute_v3_slow_relay_leaf_params(
    slow_fill_leaf: Option<V3SlowFill>,
    proof: Option<Vec<[u8; 32]>>,
    account: &Option<Account<ExecuteV3SlowRelayLeafParams>>
) -> ExecuteV3SlowRelayLeafParams {
    match (slow_fill_leaf, proof) {
        (Some(slow_fill_leaf), Some(proof)) =>
            ExecuteV3SlowRelayLeafParams {
                slow_fill_leaf,
                root_bundle_id: 0, // This is not used in the caller.
                proof,
            },
        _ =>
            account
                .as_ref()
                .map(|account| ExecuteV3SlowRelayLeafParams {
                    slow_fill_leaf: account.slow_fill_leaf.clone(),
                    root_bundle_id: account.root_bundle_id,
                    proof: account.proof.clone(),
                })
                .unwrap(), // We do not expect this to panic here as missing instruction_params is unwrapped in context.
    }
}
