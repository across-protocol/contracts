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
    pub signer: Signer<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(mut, mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut, seeds = [b"transfer_liability", mint.key().as_ref()], bump)]
    pub transfer_liability: Account<'info, TransferLiability>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: empty PDA, checked in CCTP. Seeds must be \["sender_authority"\] (CCTP Token Messenger Minter program).
    pub token_messenger_minter_sender_authority: UncheckedAccount<'info>,

    /// CHECK: MessageTransmitter is checked in CCTP. Seeds must be \["message_transmitter"\] (CCTP Message Transmitter
    // program).
    #[account(mut)]
    pub message_transmitter: UncheckedAccount<'info>,

    /// CHECK: TokenMessenger is checked in CCTP. Seeds must be \["token_messenger"\] (CCTP Token Messenger Minter
    // program).
    pub token_messenger: UncheckedAccount<'info>,

    /// CHECK: RemoteTokenMessenger is checked in CCTP. Seeds must be \["remote_token_messenger"\,
    // remote_domain.to_string()] (CCTP Token Messenger Minter program).
    pub remote_token_messenger: UncheckedAccount<'info>,

    /// CHECK: TokenMinter is checked in CCTP. Seeds must be \["token_minter"\] (CCTP Token Messenger Minter program).
    pub token_minter: UncheckedAccount<'info>,

    /// CHECK: LocalToken is checked in CCTP. Seeds must be \["local_token", mint\] (CCTP Token Messenger Minter
    // program).
    #[account(mut)]
    pub local_token: UncheckedAccount<'info>,

    /// CHECK: EventAuthority is checked in CCTP. Seeds must be \["__event_authority"\] (CCTP Token Messenger Minter
    // program).
    pub cctp_event_authority: UncheckedAccount<'info>,

    #[account(mut)]
    pub message_sent_event_data: Signer<'info>,

    pub message_transmitter_program: Program<'info, MessageTransmitter>,

    pub token_messenger_minter_program: Program<'info, TokenMessengerMinter>,

    pub token_program: Interface<'info, TokenInterface>,

    pub system_program: Program<'info, System>,
}

pub fn bridge_tokens_to_hub_pool(ctx: Context<BridgeTokensToHubPool>, amount: u64) -> Result<()> {
    if amount > ctx.accounts.transfer_liability.pending_to_hub_pool {
        return err!(SvmError::ExceededPendingBridgeAmount);
    }
    ctx.accounts.transfer_liability.pending_to_hub_pool -= amount;

    // Invoke CCTP to bridge vault tokens from state account.
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
    let state_seed_bytes = ctx.accounts.state.seed.to_le_bytes();
    let state_seeds: &[&[&[u8]]] = &[&[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]]];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, state_seeds);
    let params = DepositForBurnParams {
        amount,
        destination_domain: ctx.accounts.state.remote_domain, // CCTP domain for Mainnet Ethereum.
        mint_recipient: ctx.accounts.state.cross_domain_admin, // This is same as HubPool.
    };
    token_messenger_minter::cpi::deposit_for_burn(cpi_ctx, params)?;

    emit_cpi!(BridgedToHubPool { amount, mint: ctx.accounts.mint.key() });

    Ok(())
}
