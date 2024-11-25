use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    constants::DISCRIMINATOR_SIZE,
    constraints::is_local_or_remote_owner,
    error::SvmError,
    event::{
        EmergencyDeleteRootBundle, EnabledDepositRoute, PausedDeposits, PausedFills, RelayedRootBundle, SetXDomainAdmin,
    },
    state::{RootBundle, Route, State},
    utils::{initialize_current_time, set_seed},
};

/// Accounts required for the `Initialize` instruction.
#[derive(Accounts)]
#[instruction(seed: u64)]
pub struct Initialize<'info> {
    /// Signer responsible for initializing the state.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// State PDA account. Will be initialized with the provided seed.
    #[account(
        init, // Prevents re-initialization for the same seed.
        payer = signer,
        space = DISCRIMINATOR_SIZE + State::INIT_SPACE,
        seeds = [b"state", seed.to_le_bytes().as_ref()],
        bump
    )]
    pub state: Account<'info, State>,

    /// System program required for account initialization.
    pub system_program: Program<'info, System>,
}

/// Initializes the state account with configuration values.
///
/// # Arguments:
/// - `seed`: Seed used to derive the state account.
/// - `initial_number_of_deposits`: Initial deposit offset.
/// - `chain_id`: Chain ID for this state.
/// - `remote_domain`: CCTP domain ID for the mainnet Ethereum hub.
/// - `cross_domain_admin`: Public key of the cross-domain admin.
/// - `deposit_quote_time_buffer`: Buffer for deposit quote times.
/// - `fill_deadline_buffer`: Buffer for fill deadlines.
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
    let state = &mut ctx.accounts.state;
    state.owner = *ctx.accounts.signer.key;
    state.number_of_deposits = initial_number_of_deposits;
    state.chain_id = chain_id;
    state.remote_domain = remote_domain;
    state.cross_domain_admin = cross_domain_admin;
    state.deposit_quote_time_buffer = deposit_quote_time_buffer;
    state.fill_deadline_buffer = fill_deadline_buffer;

    // Initialize seed and current time for testing or production.
    set_seed(state, seed)?;
    initialize_current_time(state)?;

    Ok(())
}

/// Accounts required for the `PauseDeposits` instruction.
/// Used to pause or unpause deposits globally.
#[event_cpi]
#[derive(Accounts)]
pub struct PauseDeposits<'info> {
    /// Owner (local or remote) authorizing the pause action.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// State account to update the paused deposits flag.
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

/// Pauses or unpauses deposits by updating the `paused_deposits` flag.
pub fn pause_deposits(ctx: Context<PauseDeposits>, pause: bool) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.paused_deposits = pause;

    // Emit event for pause status.
    emit_cpi!(PausedDeposits { is_paused: pause });

    Ok(())
}

/// Accounts required for the `PauseFills` instruction.
/// Used to pause or unpause fills globally.
#[event_cpi]
#[derive(Accounts)]
pub struct PauseFills<'info> {
    /// Owner (local or remote) authorizing the pause action.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// State account to update the paused fills flag.
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

/// Pauses or unpauses fills by updating the `paused_fills` flag.
pub fn pause_fills(ctx: Context<PauseFills>, pause: bool) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.paused_fills = pause;

    // Emit event for pause status.
    emit_cpi!(PausedFills { is_paused: pause });

    Ok(())
}

/// Accounts required for the `TransferOwnership` instruction.
/// Enables transferring ownership of the state account.
#[derive(Accounts)]
pub struct TransferOwnership<'info> {
    /// Current owner of the state account.
    #[account(address = state.owner @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// State account to transfer ownership of.
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

/// Transfers ownership of the state account to a new owner.
pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.owner = new_owner;
    Ok(())
}

/// Accounts required for the `SetCrossDomainAdmin` instruction.
/// Allows updating the cross-domain admin.
#[event_cpi]
#[derive(Accounts)]
pub struct SetCrossDomainAdmin<'info> {
    /// Owner (local or remote) authorizing the action.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// State account to update the cross-domain admin.
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

/// Updates the cross-domain admin in the state account.
pub fn set_cross_domain_admin(ctx: Context<SetCrossDomainAdmin>, cross_domain_admin: Pubkey) -> Result<()> {
    let state = &mut ctx.accounts.state;
    state.cross_domain_admin = cross_domain_admin;

    // Emit event for cross-domain admin update.
    emit_cpi!(SetXDomainAdmin {
        new_admin: cross_domain_admin,
    });

    Ok(())
}

/// Accounts required for the `SetEnableRoute` instruction.
/// Allows enabling or disabling a route for token transfers.
#[event_cpi]
#[derive(Accounts)]
#[instruction(origin_token: Pubkey, destination_chain_id: u64)]
pub struct SetEnableRoute<'info> {
    /// Owner (local or remote) authorizing the action.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// Account paying for new routes if needed.
    #[account(mut)]
    pub payer: Signer<'info>,

    /// State account associated with the route.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Route PDA storing token transfer details.
    #[account(
        init_if_needed,
        payer = payer,
        space = DISCRIMINATOR_SIZE + Route::INIT_SPACE,
        seeds = [
            b"route",
            origin_token.as_ref(),
            state.seed.to_le_bytes().as_ref(),
            destination_chain_id.to_le_bytes().as_ref(),
        ],
        bump
    )]
    pub route: Account<'info, Route>,

    /// ATA for storing the origin token, owned by the state.
    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = origin_token_mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// Mint for the origin token. Validated against the provided address.
    #[account(
        mint::token_program = token_program,
        constraint = origin_token_mint.key() == origin_token @ SvmError::InvalidMint
    )]
    pub origin_token_mint: InterfaceAccount<'info, Mint>,

    /// Token program required for transfers.
    pub token_program: Interface<'info, TokenInterface>,

    /// Associated token program required for ATAs.
    pub associated_token_program: Program<'info, AssociatedToken>,

    /// System program required for account creation.
    pub system_program: Program<'info, System>,
}

/// Enables or disables a route for token transfers.
pub fn set_enable_route(
    ctx: Context<SetEnableRoute>,
    origin_token: Pubkey,
    destination_chain_id: u64,
    enabled: bool,
) -> Result<()> {
    ctx.accounts.route.enabled = enabled;

    // Emit event for route enablement.
    emit_cpi!(EnabledDepositRoute {
        origin_token,
        destination_chain_id,
        enabled,
    });

    Ok(())
}

/// Accounts required for the `RelayRootBundle` instruction.
/// Initializes a new root bundle to handle relays.
#[event_cpi]
#[derive(Accounts)]
pub struct RelayRootBundle<'info> {
    /// Owner (local or remote) authorizing the relay root bundle creation.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// Account paying for the creation of the root bundle.
    #[account(mut)]
    pub payer: Signer<'info>,

    /// State account associated with the root bundle.
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Root bundle PDA, initialized to store relayer refund and slow relay roots.
    #[account(
        init, // Root bundle must be initialized and cannot be re-used.
        payer = payer,
        space = DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE,
        seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), state.root_bundle_id.to_le_bytes().as_ref()],
        bump
    )]
    pub root_bundle: Account<'info, RootBundle>,

    /// System program required for creating the root bundle.
    pub system_program: Program<'info, System>,
}

/// Relays a new root bundle by initializing the relayer refund and slow relay roots.
///
/// # Arguments:
/// - `relayer_refund_root`: Merkle root for relayer refunds.
/// - `slow_relay_root`: Merkle root for slow relays.
pub fn relay_root_bundle(
    ctx: Context<RelayRootBundle>,
    relayer_refund_root: [u8; 32],
    slow_relay_root: [u8; 32],
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    let root_bundle = &mut ctx.accounts.root_bundle;

    // Set the relayer refund and slow relay roots in the root bundle.
    root_bundle.relayer_refund_root = relayer_refund_root;
    root_bundle.slow_relay_root = slow_relay_root;

    // Emit an event for the relayed root bundle.
    emit_cpi!(RelayedRootBundle {
        root_bundle_id: state.root_bundle_id,
        relayer_refund_root,
        slow_relay_root,
    });

    // Increment the root bundle ID for the next bundle.
    state.root_bundle_id += 1;

    Ok(())
}

/// Accounts required for the `EmergencyDeleteRootBundleState` instruction.
/// Used to delete a root bundle in emergency scenarios.
#[event_cpi]
#[derive(Accounts)]
#[instruction(root_bundle_id: u32)]
pub struct EmergencyDeleteRootBundleState<'info> {
    /// Owner (local or remote) authorizing the emergency deletion.
    #[account(constraint = is_local_or_remote_owner(&signer, &state) @ SvmError::NotOwner)]
    pub signer: Signer<'info>,

    /// System account to receive lamports from the closed root bundle.
    #[account(mut)]
    // We do not restrict who can receive lamports from closing root_bundle account as that would require storing the
    // original payer when root bundle was relayed and unnecessarily make it more expensive to relay in the happy path.
    pub closer: SystemAccount<'info>,

    /// State account associated with the root bundle.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Root bundle PDA to be deleted.
    #[account(
        mut,
        seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), root_bundle_id.to_le_bytes().as_ref()],
        close = closer,
        bump
    )]
    pub root_bundle: Account<'info, RootBundle>,
}

/// Deletes a root bundle in case of an emergency.
///
/// # Arguments:
/// - `root_bundle_id`: ID of the root bundle to be deleted.
pub fn emergency_delete_root_bundle(ctx: Context<EmergencyDeleteRootBundleState>, root_bundle_id: u32) -> Result<()> {
    // Emit an event for the emergency deletion.
    emit_cpi!(EmergencyDeleteRootBundle { root_bundle_id });

    Ok(())
}
