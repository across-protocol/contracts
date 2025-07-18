use anchor_lang::prelude::*;

use crate::{
    constants::DISCRIMINATOR_SIZE,
    constraints::is_local_or_remote_owner,
    error::SvmError,
    event::{
        EmergencyDeletedRootBundle, PausedDeposits, PausedFills, RelayedRootBundle, SetXDomainAdmin,
        TransferredOwnership,
    },
    state::{RootBundle, State},
    utils::{initialize_current_time, set_seed},
};

#[derive(Accounts)]
#[instruction(seed: u64)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        init, // Use init, not init_if_needed to prevent re-initialization.
        payer = signer,
        space = DISCRIMINATOR_SIZE + State::INIT_SPACE,
        seeds = [b"state", seed.to_le_bytes().as_ref()],
        bump
    )]
    pub state: Account<'info, State>,

    pub system_program: Program<'info, System>,
}

pub fn initialize(
    ctx: Context<Initialize>,
    seed: u64,                       // Seed used to derive a new state to enable testing to reset between runs.
    initial_number_of_deposits: u32, // Starting number of deposits to offset deposit_id.
    chain_id: u64,                   // Across definition of chainId for Solana.
    remote_domain: u32,              // CCTP domain for Mainnet Ethereum.
    cross_domain_admin: Pubkey,      // HubPool on Mainnet Ethereum.
    deposit_quote_time_buffer: u32,  // Deposit quote times can't be set more than this amount into the past/future.
    fill_deadline_buffer: u32,       // Fill deadlines can't be set more than this amount into the future.
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = *ctx.accounts.signer.key;
    state.number_of_deposits = initial_number_of_deposits;
    state.chain_id = chain_id;
    state.remote_domain = remote_domain;
    state.cross_domain_admin = cross_domain_admin;
    state.deposit_quote_time_buffer = deposit_quote_time_buffer;
    state.fill_deadline_buffer = fill_deadline_buffer;

    // Set seed and initialize current time. Both enable testing functionality and are no-ops in production.
    set_seed(state, seed)?;
    initialize_current_time(state)?;

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct PauseDeposits<'info> {
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn pause_deposits(ctx: Context<PauseDeposits>, pause: bool) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.paused_deposits = pause;

    emit_cpi!(PausedDeposits { is_paused: pause });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct PauseFills<'info> {
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn pause_fills(ctx: Context<PauseFills>, pause: bool) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.paused_fills = pause;

    emit_cpi!(PausedFills { is_paused: pause });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct TransferOwnership<'info> {
    #[account(address = state.owner @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = new_owner;

    emit_cpi!(TransferredOwnership { new_owner });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetCrossDomainAdmin<'info> {
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn set_cross_domain_admin(ctx: Context<SetCrossDomainAdmin>, cross_domain_admin: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.cross_domain_admin = cross_domain_admin;

    emit_cpi!(SetXDomainAdmin { new_admin: cross_domain_admin });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct RelayRootBundle<'info> {
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        init, // Init to create root bundle account. Prevents re-initialization for a given root..
        payer = payer,
        space = DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE,
        seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), state.root_bundle_id.to_le_bytes().as_ref()],
        bump
    )]
    pub root_bundle: Account<'info, RootBundle>,

    pub system_program: Program<'info, System>,
}

pub fn relay_root_bundle(
    ctx: Context<RelayRootBundle>,
    relayer_refund_root: [u8; 32],
    slow_relay_root: [u8; 32],
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let root_bundle = &mut ctx.accounts.root_bundle;
    root_bundle.relayer_refund_root = relayer_refund_root;
    root_bundle.slow_relay_root = slow_relay_root;

    emit_cpi!(RelayedRootBundle { root_bundle_id: state.root_bundle_id, relayer_refund_root, slow_relay_root });

    state.root_bundle_id += 1;

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(root_bundle_id: u32)]
pub struct EmergencyDeleteRootBundleState<'info> {
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    #[account(mut)]
    // We do not restrict who can receive lamports from closing root_bundle account as that would require storing the
    // original payer when root bundle was relayed and unnecessarily make it more expensive to relay in the happy path.
    pub closer: SystemAccount<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut,
        seeds =[b"root_bundle", state.seed.to_le_bytes().as_ref(), root_bundle_id.to_le_bytes().as_ref()],
        close = closer,
        bump)]
    pub root_bundle: Account<'info, RootBundle>,
}

pub fn emergency_delete_root_bundle(ctx: Context<EmergencyDeleteRootBundleState>, root_bundle_id: u32) -> Result<()> {
    emit_cpi!(EmergencyDeletedRootBundle { root_bundle_id });

    Ok(())
}
