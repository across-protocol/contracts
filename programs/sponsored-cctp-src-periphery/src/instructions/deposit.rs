use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    message_transmitter_v2::program::MessageTransmitterV2,
    token_messenger_minter_v2::{cpi::accounts::DepositForBurnWithHook, program::TokenMessengerMinterV2},
    State,
};

#[event_cpi]
#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub signer: Signer<'info>, // TODO: Consider if we need delegation flow similar as in SVM Spoke program.

    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = signer,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    /// CHECK: denylist PDA, checked in CCTP. Seeds must be ["denylist_account", signer.key()] (CCTP
    // TokenMessengerMinterV2 program).
    pub token_messenger_minter_denylist_account: UncheckedAccount<'info>,

    /// CHECK: empty PDA, checked in CCTP. Seeds must be ["sender_authority"] (CCTP TokenMessengerMinterV2 program).
    pub token_messenger_minter_sender_authority: UncheckedAccount<'info>,

    /// CHECK: MessageTransmitter is checked in CCTP. Seeds must be ["message_transmitter"] (CCTP TokenMessengerMinterV2
    // program).
    #[account(mut)]
    pub message_transmitter: UncheckedAccount<'info>,

    /// CHECK: TokenMessenger is checked in CCTP. Seeds must be ["token_messenger"] (CCTP TokenMessengerMinterV2
    // program).
    pub token_messenger: UncheckedAccount<'info>,

    /// CHECK: RemoteTokenMessenger is checked in CCTP. Seeds must be ["remote_token_messenger",
    // remote_domain.to_string()] (CCTP TokenMessengerMinterV2 program).
    pub remote_token_messenger: UncheckedAccount<'info>,

    /// CHECK: TokenMinter is checked in CCTP. Seeds must be ["token_minter"] (CCTP TokenMessengerMinterV2 program).
    pub token_minter: UncheckedAccount<'info>,

    /// CHECK: LocalToken is checked in CCTP. Seeds must be ["local_token", mint.key()] (CCTP TokenMessengerMinterV2
    // program).
    #[account(mut)]
    pub local_token: UncheckedAccount<'info>,

    /// CHECK: EventAuthority is checked in CCTP. Seeds must be ["__event_authority"] (CCTP TokenMessengerMinterV2
    // program).
    pub cctp_event_authority: UncheckedAccount<'info>,

    // Account to store MessageSent CCTP event data in. Any non-PDA uninitialized address.
    #[account(mut)]
    pub message_sent_event_data: Signer<'info>,

    pub message_transmitter_program: Program<'info, MessageTransmitterV2>,

    pub token_messenger_minter_program: Program<'info, TokenMessengerMinterV2>,

    pub token_program: Interface<'info, TokenInterface>,

    pub system_program: Program<'info, System>,
}

// TODO: Add SponsoredCCTPQuote and signature parameters.
pub fn deposit(ctx: Context<Deposit>) -> Result<()> {
    // TODO: Validate the signature of SponsoredCCTPQuote matches expected signer.

    // TODO: Validate the decoded SponsoredCCTPQuote parameters.

    // Invoke CCTPv2 to bridge user tokens.
    let cpi_program = ctx.accounts.token_messenger_minter_program.to_account_info();
    let cpi_accounts = DepositForBurnWithHook {
        owner: ctx.accounts.signer.to_account_info(),
        event_rent_payer: ctx.accounts.payer.to_account_info(),
        sender_authority_pda: ctx.accounts.token_messenger_minter_sender_authority.to_account_info(),
        burn_token_account: ctx.accounts.depositor_token_account.to_account_info(),
        denylist_account: ctx.accounts.token_messenger_minter_denylist_account.to_account_info(),
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

    // TODO: Get required parameters from SponsoredCCTPQuote and CPI deposit_for_burn_with_hook with user signatures.
    // Note that this would burn tokens on behalf of the user and show the signer address as messageSender on the
    // destination chain.

    // TODO: Emit event.

    Ok(())
}
