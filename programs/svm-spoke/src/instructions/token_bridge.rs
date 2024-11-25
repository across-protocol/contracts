use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    error::SvmError,
    event::BridgedToHubPool,
    message_transmitter::program::MessageTransmitter,
    token_messenger_minter::{
        self, cpi::accounts::DepositForBurn, program::TokenMessengerMinter, types::DepositForBurnParams,
    },
    State, TransferLiability,
};

#[event_cpi]
#[derive(Accounts)]
pub struct BridgeTokensToHubPool<'info> {
    /// Signer initiating the bridge.
    pub signer: Signer<'info>,

    /// Signer paying for the message transmission.
    #[account(mut)]
    pub payer: Signer<'info>,

    /// Token mint of the asset being bridged.
    #[account(mut, mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    /// State account containing global configuration.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Transfer liability account tracking pending bridge amounts.
    #[account(mut, seeds = [b"transfer_liability", mint.key().as_ref()], bump)]
    pub transfer_liability: Account<'info, TransferLiability>,

    /// Vault holding the tokens to be bridged, owned by the state.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: Empty PDA validated by CCTP. Represents the sender authority in the CCTP program.
    pub token_messenger_minter_sender_authority: UncheckedAccount<'info>,

    /// CHECK: MessageTransmitter PDA validated by CCTP. Represents the message transmitter.
    #[account(mut)]
    pub message_transmitter: UncheckedAccount<'info>,

    /// CHECK: TokenMessenger PDA validated by CCTP.
    pub token_messenger: UncheckedAccount<'info>,

    /// CHECK: RemoteTokenMessenger PDA validated by CCTP. Represents the token messenger for the remote domain.
    pub remote_token_messenger: UncheckedAccount<'info>,

    /// CHECK: TokenMinter PDA validated by CCTP.
    pub token_minter: UncheckedAccount<'info>,

    /// CHECK: LocalToken PDA validated by CCTP. Represents the local token associated with the mint.
    #[account(mut)]
    pub local_token: UncheckedAccount<'info>,

    /// CHECK: EventAuthority PDA validated by CCTP.
    pub cctp_event_authority: UncheckedAccount<'info>,

    /// Data account used for storing event metadata during the bridging process.
    #[account(mut)]
    pub message_sent_event_data: Signer<'info>,

    /// CCTP message transmitter program.
    pub message_transmitter_program: Program<'info, MessageTransmitter>,

    /// CCTP token messenger minter program.
    pub token_messenger_minter_program: Program<'info, TokenMessengerMinter>,

    /// Token program for CPI interactions.
    pub token_program: Interface<'info, TokenInterface>,

    /// System program for account initialization.
    pub system_program: Program<'info, System>,
}

/// Bridges tokens from the vault to the HubPool using CCTP.
///
/// Parameters:
/// - `ctx`: The context for the bridge.
/// - `amount`: The amount of tokens to bridge.
pub fn bridge_tokens_to_hub_pool(ctx: Context<BridgeTokensToHubPool>, amount: u64) -> Result<()> {
    // Validate the requested amount does not exceed the pending liability.
    if amount > ctx.accounts.transfer_liability.pending_to_hub_pool {
        return err!(SvmError::ExceededPendingBridgeAmount);
    }
    ctx.accounts.transfer_liability.pending_to_hub_pool -= amount;

    // Prepare the CCTP `deposit_for_burn` context.
    let cpi_program = ctx.accounts.token_messenger_minter_program.to_account_info();
    let cpi_accounts = DepositForBurn {
        owner: ctx.accounts.state.to_account_info(),
        event_rent_payer: ctx.accounts.payer.to_account_info(),
        sender_authority_pda: ctx.accounts.token_messenger_minter_sender_authority.to_account_info(),
        burn_token_account: ctx.accounts.vault.to_account_info(),
        message_transmitter: ctx.accounts.message_transmitter.to_account_info(),
        token_messenger: ctx.accounts.token_messenger.to_account_info(),
        remote_token_messenger: ctx.accounts.remote_token_messenger.to_account_info(),
        token_minter: ctx.accounts.token_minter.to_account_info(),
        local_token: ctx.accounts.local_token.to_account_info(),
        burn_token_mint: ctx.accounts.mint.to_account_info(),
        message_sent_event_data: ctx.accounts.message_sent_event_data.to_account_info(),
        message_transmitter_program: ctx.accounts.message_transmitter_program.to_account_info(),
        token_messenger_minter_program: ctx.accounts.token_messenger_minter_program.to_account_info(),
        token_program: ctx.accounts.token_program.to_account_info(),
        system_program: ctx.accounts.system_program.to_account_info(),
        event_authority: ctx.accounts.cctp_event_authority.to_account_info(),
        program: ctx.accounts.token_messenger_minter_program.to_account_info(),
    };

    // Generate the state signer seeds.
    let state_seed_bytes = ctx.accounts.state.seed.to_le_bytes();
    let state_seeds: &[&[&[u8]]] = &[&[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]]];

    // Create the CPI context with signer seeds.
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, state_seeds);

    // Define the parameters for the CCTP `deposit_for_burn` call.
    let params = DepositForBurnParams {
        amount,
        destination_domain: ctx.accounts.state.remote_domain, // CCTP domain for the HubPool (e.g., Mainnet Ethereum).
        mint_recipient: ctx.accounts.state.cross_domain_admin, // HubPool address.
    };

    // Call the CCTP `deposit_for_burn` instruction.
    token_messenger_minter::cpi::deposit_for_burn(cpi_ctx, params)?;

    emit_cpi!(BridgedToHubPool {
        amount,
        mint: ctx.accounts.mint.key(),
    });

    Ok(())
}
