use anchor_lang::prelude::*;

use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::constants::DISCRIMINATOR_SIZE;
use crate::constraints::is_local_or_remote_owner;

use crate::{
    error::CustomError,
    state::{RootBundle, Route, State},
};

//TODO: there is too much in this file now and it should be split up somewhat.

#[derive(Accounts)]
#[instruction(seed: u64, initial_number_of_deposits: u64, chain_id: u64)] // Add chain_id to instruction
pub struct Initialize<'info> {
    #[account(init, // Use init, not init_if_needed to prevent re-initialization.
              payer = signer,
              space = DISCRIMINATOR_SIZE + State::INIT_SPACE,
              seeds = [b"state", seed.to_le_bytes().as_ref()],
              bump)]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn initialize(
    ctx: Context<Initialize>,
    seed: u64,
    initial_number_of_deposits: u64,
    chain_id: u64,              // Across definition of chainId for Solana.
    remote_domain: u32,         // CCTP domain for Mainnet Ethereum.
    cross_domain_admin: Pubkey, // HubPool on Mainnet Ethereum.
    testable_mode: bool,        // If the contract is in testable mode, enabling time manipulation.
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = *ctx.accounts.signer.key;
    state.seed = seed; // Set the seed in the state
    state.number_of_deposits = initial_number_of_deposits; // Set initial number of deposits
    state.chain_id = chain_id;
    state.remote_domain = remote_domain;
    state.cross_domain_admin = cross_domain_admin;
    state.current_time = if testable_mode {
        Clock::get()?.unix_timestamp as u32
    } else {
        0
    }; // Set current_time to system time if testable_mode is true, else 0
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
        address = state.owner @ CustomError::NotOwner
    )]
    pub signer: Signer<'info>,
}

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

    emit_cpi!(SetXDomainAdmin {
        new_admin: cross_domain_admin,
    });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(origin_token: [u8; 32], destination_chain_id: u64)]
pub struct SetEnableRoute<'info> {
    #[account(
        mut,
        constraint = is_local_or_remote_owner(&signer, &state) @ CustomError::NotOwner
    )]
    pub signer: Signer<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        init_if_needed,
        payer = payer,
        space = DISCRIMINATOR_SIZE + Route::INIT_SPACE,
        seeds = [b"route", origin_token.as_ref(), destination_chain_id.to_le_bytes().as_ref()],
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

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    // TODO: consider deriving seed from state.seed instead of state.key() as this could be cheaper (need to verify).
    #[account(init,
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
    Ok(())
}
#[event]
pub struct SetXDomainAdmin {
    pub new_admin: Pubkey,
}

#[event]
pub struct PausedDeposits {
    pub is_paused: bool,
}

#[event]
pub struct PausedFills {
    pub is_paused: bool,
}

#[event]
pub struct EnabledDepositRoute {
    pub origin_token: Pubkey,
    pub destination_chain_id: u64,
    pub enabled: bool,
}
