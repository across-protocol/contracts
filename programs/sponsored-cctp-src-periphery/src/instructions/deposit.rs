use anchor_lang::{prelude::*, system_program};
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

pub use crate::message_transmitter_v2::types::ReclaimEventAccountParams;
use crate::{
    error::{CommonError, SvmError},
    event::{ReclaimedEventAccount, ReclaimedUsedNonceAccount, SponsoredDepositForBurn},
    message_transmitter_v2::{self, program::MessageTransmitterV2},
    state::{State, UsedNonce},
    token_messenger_minter_v2::{
        self, cpi::accounts::DepositForBurnWithHook, program::TokenMessengerMinterV2,
        types::DepositForBurnWithHookParams,
    },
    utils::{get_current_time, validate_signature, SponsoredCCTPQuote, NONCE_END, NONCE_START},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(params: DepositParams)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub signer: Signer<'info>, // TODO: Consider if we need delegation flow similar as in SVM Spoke program.

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    #[account(
        init, // This enforces that a given quote nonce can be used only once.
        payer = signer,
        space = UsedNonce::DISCRIMINATOR.len() + UsedNonce::INIT_SPACE,
        seeds = [
            b"used_nonce",
            &params.quote[NONCE_START..NONCE_END], // Using quote nonce as seed to create a unique nonce account.
        ],
        bump
    )]
    pub used_nonce: Account<'info, UsedNonce>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = signer,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    // Mint key is not checked against the quoted burn_token here to avoid the overhead of deserializing and parsing the
    // quote. Instead this check is performed in the instruction handler.
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

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct DepositParams {
    pub quote: Vec<u8>, // This is fixed length, but using Vec so it is shown as encoded data blob in explorers.
    pub signature: Vec<u8>, // This is fixed length, but using Vec so it is shown as encoded data blob in explorers.
}

pub fn deposit(ctx: Context<Deposit>, params: &DepositParams) -> Result<()> {
    // Repay user for used_nonce account creation as the rent_fund account will receive its balance upon closing.
    refund_used_nonce(&ctx)?;

    let state = &ctx.accounts.state;

    let quote = SponsoredCCTPQuote::new(&params.quote)?;
    validate_signature(state.signer, &quote, &params.signature)?;

    let amount = quote.amount()?;
    let destination_domain = quote.destination_domain()?;
    let mint_recipient = quote.mint_recipient()?;
    let burn_token = quote.burn_token()?;
    let destination_caller = quote.destination_caller()?;
    let max_fee = quote.max_fee()?;
    let min_finality_threshold = quote.min_finality_threshold()?;
    let hook_data = quote.hook_data();

    if burn_token != ctx.accounts.mint.key() {
        return err!(SvmError::InvalidMint);
    }

    let quote_deadline = quote.deadline()?;
    if quote_deadline < get_current_time(state)? {
        return err!(CommonError::InvalidDeadline);
    }
    if quote.source_domain()? != state.local_domain {
        return err!(CommonError::InvalidSourceDomain);
    }

    // Record the quote deadline as it should be safe to close the used_nonce account after this time.
    ctx.accounts.used_nonce.quote_deadline = quote_deadline;

    // Invoke CCTPv2 to bridge user tokens.
    // TODO: Confirm it is acceptable to burn tokens on behalf of the user and have the signer address show up as
    // messageSender on the destination chain.
    let cpi_program = ctx.accounts.token_messenger_minter_program.to_account_info();
    let cpi_accounts = DepositForBurnWithHook {
        owner: ctx.accounts.signer.to_account_info(),
        event_rent_payer: ctx.accounts.rent_fund.to_account_info(),
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
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, rent_fund_seeds);
    let cpi_params = DepositForBurnWithHookParams {
        amount,
        destination_domain,
        mint_recipient,
        destination_caller,
        max_fee,
        min_finality_threshold,
        hook_data,
    };
    token_messenger_minter_v2::cpi::deposit_for_burn_with_hook(cpi_ctx, cpi_params)?;

    emit_cpi!(SponsoredDepositForBurn {
        quote_nonce: quote.nonce()?.to_vec(),
        origin_sender: ctx.accounts.signer.key(),
        final_recipient: quote.final_recipient()?,
        quote_deadline: quote.deadline()?,
        max_bps_to_sponsor: quote.max_bps_to_sponsor()?,
        final_token: quote.final_token()?,
        signature: params.signature.clone(),
    });

    Ok(())
}

fn refund_used_nonce(ctx: &Context<Deposit>) -> Result<()> {
    let anchor_rent = Rent::get()?;
    let space = UsedNonce::DISCRIMINATOR.len() + UsedNonce::INIT_SPACE;

    // Actual cost for the user might have been lower if somebody had pre-funded the used_nonce account, but that should
    // be of no concern as the rent_fund account will receive the whole balance upon its closure.
    let lamports = anchor_rent.minimum_balance(space);

    let cpi_accounts = system_program::Transfer {
        from: ctx.accounts.rent_fund.to_account_info(),
        to: ctx.accounts.signer.to_account_info(),
    };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_context =
        CpiContext::new_with_signer(ctx.accounts.system_program.to_account_info(), cpi_accounts, rent_fund_seeds);
    system_program::transfer(cpi_context, lamports)?;

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct ReclaimEventAccount<'info> {
    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    /// CHECK: MessageTransmitter is checked in CCTP. Seeds must be ["message_transmitter"] (CCTP TokenMessengerMinterV2
    // program).
    #[account(mut)]
    pub message_transmitter: UncheckedAccount<'info>,

    /// CHECK: MessageSent is checked in CCTP, must be the same account as in Deposit instruction.
    #[account(mut)]
    pub message_sent_event_data: UncheckedAccount<'info>,

    pub message_transmitter_program: Program<'info, MessageTransmitterV2>,
}

pub fn reclaim_event_account(ctx: Context<ReclaimEventAccount>, params: &ReclaimEventAccountParams) -> Result<()> {
    let cpi_program = ctx.accounts.message_transmitter_program.to_account_info();
    let cpi_accounts = message_transmitter_v2::cpi::accounts::ReclaimEventAccount {
        payee: ctx.accounts.rent_fund.to_account_info(),
        message_transmitter: ctx.accounts.message_transmitter.to_account_info(),
        message_sent_event_data: ctx.accounts.message_sent_event_data.to_account_info(),
    };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, rent_fund_seeds);
    message_transmitter_v2::cpi::reclaim_event_account(cpi_ctx, params.clone())?;

    emit_cpi!(ReclaimedEventAccount { message_sent_event_data: ctx.accounts.message_sent_event_data.key() });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(params: ReclaimUsedNonceAccountParams)]
pub struct ReclaimUsedNonceAccount<'info> {
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    #[account(
        mut,
        close = rent_fund,
        seeds = [b"used_nonce",&params.nonce.as_ref()],
        bump
    )]
    pub used_nonce: Account<'info, UsedNonce>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ReclaimUsedNonceAccountParams {
    pub nonce: [u8; 32],
}

pub fn reclaim_used_nonce_account(
    ctx: Context<ReclaimUsedNonceAccount>,
    params: &ReclaimUsedNonceAccountParams,
) -> Result<()> {
    if ctx.accounts.used_nonce.quote_deadline >= get_current_time(&ctx.accounts.state)? {
        return err!(SvmError::QuoteDeadlineNotPassed);
    }

    emit_cpi!(ReclaimedUsedNonceAccount { nonce: params.nonce.to_vec(), used_nonce: ctx.accounts.used_nonce.key() });

    Ok(())
}
