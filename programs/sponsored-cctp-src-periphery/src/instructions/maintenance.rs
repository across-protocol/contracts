use anchor_lang::{prelude::*, system_program};

pub use crate::message_transmitter_v2::types::ReclaimEventAccountParams;
use crate::{
    error::SvmError,
    event::{ReclaimedEventAccount, ReclaimedUsedNonceAccount, RepaidRentFundDebt},
    message_transmitter_v2::{self, program::MessageTransmitterV2},
    state::{RentClaim, State, UsedNonce},
    utils::get_current_time,
};

#[event_cpi]
#[derive(Accounts)]
pub struct RepayRentFundDebt<'info> {
    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    /// CHECK: Recipient is checked in rent_claim PDA derivation.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    #[account(
        mut,
        close = recipient,
        seeds = [b"rent_claim", recipient.key().as_ref()],
        bump
    )]
    pub rent_claim: Account<'info, RentClaim>,

    pub system_program: Program<'info, System>,
}

pub fn repay_rent_fund_debt(ctx: Context<RepayRentFundDebt>) -> Result<()> {
    let anchor_rent = Rent::get()?;

    // Debt amount might be zero if user had passed Some rent_claim account without accruing any rent_fund debt in the
    // deposit. Exit early in this case so that rent_claim account can be closed.
    let amount = ctx.accounts.rent_claim.amount;
    if amount == 0 {
        return Ok(());
    }

    // Check if rent fund has enough balance to repay the debt and remain rent-exempt.
    let max_repay = ctx
        .accounts
        .rent_fund
        .lamports()
        .saturating_sub(anchor_rent.minimum_balance(0));
    if max_repay < amount {
        return err!(SvmError::InsufficientRentFundBalance);
    }

    let cpi_accounts = system_program::Transfer {
        from: ctx.accounts.rent_fund.to_account_info(),
        to: ctx.accounts.recipient.to_account_info(),
    };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_context =
        CpiContext::new_with_signer(ctx.accounts.system_program.to_account_info(), cpi_accounts, rent_fund_seeds);
    system_program::transfer(cpi_context, amount)?;

    emit_cpi!(RepaidRentFundDebt { user: ctx.accounts.recipient.key(), amount });

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

    /// CHECK: MessageSent is checked in CCTP, must be the same account as in DepositForBurn.
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
#[instruction(params: UsedNonceAccountParams)]
pub struct ReclaimUsedNonceAccount<'info> {
    #[account(seeds = [b"state"], bump)]
    pub state: Account<'info, State>,

    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    #[account(mut, close = rent_fund, seeds = [b"used_nonce", &params.nonce.as_ref()], bump)]
    pub used_nonce: Account<'info, UsedNonce>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct UsedNonceAccountParams {
    pub nonce: [u8; 32],
}

pub fn reclaim_used_nonce_account(
    ctx: Context<ReclaimUsedNonceAccount>,
    params: &UsedNonceAccountParams,
) -> Result<()> {
    if ctx.accounts.used_nonce.quote_deadline >= get_current_time(&ctx.accounts.state)? {
        return err!(SvmError::QuoteDeadlineNotPassed);
    }

    emit_cpi!(ReclaimedUsedNonceAccount { nonce: params.nonce.to_vec(), used_nonce: ctx.accounts.used_nonce.key() });

    Ok(())
}

#[derive(Accounts)]
#[instruction(_params: UsedNonceAccountParams)]
pub struct GetUsedNonceCloseInfo<'info> {
    #[account(seeds = [b"state"], bump)]
    pub state: Account<'info, State>,

    #[account(seeds = [b"used_nonce", &_params.nonce.as_ref()], bump)]
    pub used_nonce: Account<'info, UsedNonce>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct UsedNonceCloseInfo {
    pub can_close_after: u64,
    pub can_close_now: bool,
}

pub fn get_used_nonce_close_info(ctx: Context<GetUsedNonceCloseInfo>) -> Result<UsedNonceCloseInfo> {
    let can_close_after = ctx.accounts.used_nonce.quote_deadline;
    let can_close_now = can_close_after < get_current_time(&ctx.accounts.state)?;

    Ok(UsedNonceCloseInfo { can_close_after, can_close_now })
}
