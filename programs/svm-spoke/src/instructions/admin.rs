use anchor_lang::prelude::*;

// TODO: standardize imports across all files
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

// TODO: check that the discriminator size is used everywhere
use crate::constants::DISCRIMINATOR_SIZE;
use crate::constraints::is_local_or_remote_owner;

use crate::{
    error::CustomError,
    event::{EnabledDepositRoute, PausedDeposits, PausedFills, SetXDomainAdmin},
    initialize_current_time,
    state::{RootBundle, Route, State},
};

#[derive(Accounts)]
#[instruction(seed: u64)]
pub struct Initialize<'info> {
    #[account(init, // Use init, not init_if_needed to prevent re-initialization.
              payer = signer,
              space = DISCRIMINATOR_SIZE + State::INIT_SPACE, // TODO: check that INIT_SPACE is used everywhere
              seeds = [b"state", seed.to_le_bytes().as_ref()], // TODO: can we set a blank seed? or something better?
              bump)]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn initialize(
    ctx: Context<Initialize>,
    seed: u64,
    initial_number_of_deposits: u32,
    chain_id: u64,                  // Across definition of chainId for Solana.
    remote_domain: u32,             // CCTP domain for Mainnet Ethereum.
    cross_domain_admin: Pubkey,     // HubPool on Mainnet Ethereum.
    deposit_quote_time_buffer: u32, // Deposit quote times can't be set more than this amount into the past/future.
    fill_deadline_buffer: u32, // Fill deadlines can't be set more than this amount into the future.
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = *ctx.accounts.signer.key;
    state.seed = seed; // Set the seed in the state
    state.number_of_deposits = initial_number_of_deposits; // Set initial number of deposits
    state.chain_id = chain_id;
    state.remote_domain = remote_domain;
    state.cross_domain_admin = cross_domain_admin;
    state.deposit_quote_time_buffer = deposit_quote_time_buffer;
    state.fill_deadline_buffer = fill_deadline_buffer;

    initialize_current_time(state)?; // Stores current time in test build (no-op in production).

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct PauseDeposits<'info> {
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
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
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
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

#[derive(Accounts)]
pub struct TransferOwnership<'info> {
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        mut,
        address = state.owner @ CustomError::NotOwner // TODO: test permissioning with a multi-sig and Squads
    )]
    pub signer: Signer<'info>,
}

// TODO: check that the recovery flow is similar to the one in EVM
pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = new_owner;
    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetCrossDomainAdmin<'info> {
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn set_cross_domain_admin(
    ctx: Context<SetCrossDomainAdmin>,
    cross_domain_admin: Pubkey,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.cross_domain_admin = cross_domain_admin;

    // TODO: add lint to make this a 1-liner
    emit_cpi!(SetXDomainAdmin {
        new_admin: cross_domain_admin,
    });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(origin_token: [u8; 32], destination_chain_id: u64)] // TODO: is it possible to replace origin_token with Pubkey?
pub struct SetEnableRoute<'info> {
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
    pub signer: Signer<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    // TODO: check if state needs to be mut here and in other places
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        init_if_needed,
        payer = payer,
        space = DISCRIMINATOR_SIZE + Route::INIT_SPACE,
        seeds = [b"route", origin_token.as_ref(), state.key().as_ref(), destination_chain_id.to_le_bytes().as_ref()],
        bump
    )]
    pub route: Account<'info, Route>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = origin_token_mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mint::token_program = token_program,
        // IDL build fails when requiring `address = input_token` for mint, thus using a custom constraint.
        constraint = origin_token_mint.key() == origin_token.into() @ CustomError::InvalidMint
    )]
    pub origin_token_mint: InterfaceAccount<'info, Mint>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn set_enable_route(
    ctx: Context<SetEnableRoute>,
    origin_token: [u8; 32],
    destination_chain_id: u64,
    enabled: bool,
) -> Result<()> {
    ctx.accounts.route.enabled = enabled;

    emit_cpi!(EnabledDepositRoute {
        origin_token: Pubkey::new_from_array(origin_token),
        destination_chain_id,
        enabled,
    });

    Ok(())
}

#[derive(Accounts)]
pub struct RelayRootBundle<'info> {
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
    pub signer: Signer<'info>,

    // TODO: standardize usage of state.seed vs state.key()
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    // TODO: consider deriving seed from state.seed instead of state.key() as this could be cheaper (need to verify).
    #[account(init, // TODO: add comment explaining why init
        payer = signer,
        space = DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE,
        seeds =[b"root_bundle", state.key().as_ref(), state.root_bundle_id.to_le_bytes().as_ref()],
        bump)]
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
    state.root_bundle_id += 1;

    // TODO: add event
    Ok(())
}

// TODO: add emergency_delete_root_bundle
