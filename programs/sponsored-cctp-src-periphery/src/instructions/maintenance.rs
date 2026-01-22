use anchor_lang::{prelude::*, system_program};

pub use crate::message_transmitter_v2::types::ReclaimEventAccountParams as ReclaimEventAccountCctpV2Params;
use crate::{
    error::SvmError,
    event::{ReclaimedEventAccount, ReclaimedUsedNonceAccount, RepaidRentFundDebt},
    message_transmitter_v2::{self, accounts::MessageSent, program::MessageTransmitterV2},
    state::{RentClaim, State, UsedNonce},
    utils::{build_destination_message, get_current_time},
};

#[event_cpi]
#[derive(Accounts)]
pub struct RepayRentFundDebt<'info> {
    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    /// CHECK: Recipient is checked in rent_claim PDA derivation.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    #[account(mut, seeds = [b"rent_claim", recipient.key().as_ref()], bump)]
    pub rent_claim: Account<'info, RentClaim>,

    pub system_program: Program<'info, System>,
}

pub fn repay_rent_fund_debt(ctx: Context<RepayRentFundDebt>) -> Result<()> {
    let anchor_rent = Rent::get()?;

    let rent_claim = &mut ctx.accounts.rent_claim;

    // Check if rent fund has enough balance to repay any non-zero debt and remain rent-exempt.
    let max_repay = ctx
        .accounts
        .rent_fund
        .lamports()
        .saturating_sub(anchor_rent.minimum_balance(0));
    let repay_amount = rent_claim.amount.min(max_repay);
    if repay_amount == 0 {
        // Deposit instruction closes rent_claim account with zero debt, so return early if cannot repay any part of it.
        return Ok(());
    }

    let cpi_accounts = system_program::Transfer {
        from: ctx.accounts.rent_fund.to_account_info(),
        to: ctx.accounts.recipient.to_account_info(),
    };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_context =
        CpiContext::new_with_signer(ctx.accounts.system_program.to_account_info(), cpi_accounts, rent_fund_seeds);
    system_program::transfer(cpi_context, repay_amount)?;

    // Update the remaining debt, safe to subtract repay_amount as it is guaranteed to be <= rent_claim.amount.
    rent_claim.amount -= repay_amount;

    emit_cpi!(RepaidRentFundDebt {
        user: ctx.accounts.recipient.key(),
        amount: repay_amount,
        remaining_user_claim: rent_claim.amount,
    });

    // Close the claim account if the debt is fully repaid.
    if rent_claim.amount == 0 {
        rent_claim.close(ctx.accounts.recipient.to_account_info())?;
    }

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

    #[account(mut)]
    pub message_sent_event_data: Account<'info, MessageSent>,

    pub message_transmitter_program: Program<'info, MessageTransmitterV2>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ReclaimEventAccountParams {
    pub attestation: Vec<u8>,
    pub nonce: [u8; 32],
    pub finality_threshold_executed: [u8; 4],
    pub fee_executed: [u8; 32],
    pub expiration_block: [u8; 32],
}

pub fn reclaim_event_account(ctx: Context<ReclaimEventAccount>, params: &ReclaimEventAccountParams) -> Result<()> {
    let destination_message = build_destination_message(&ctx.accounts.message_sent_event_data.message, params)?;
    let cctp_v2_params =
        ReclaimEventAccountCctpV2Params { attestation: params.attestation.clone(), destination_message };

    let cpi_program = ctx.accounts.message_transmitter_program.to_account_info();
    let cpi_accounts = message_transmitter_v2::cpi::accounts::ReclaimEventAccount {
        payee: ctx.accounts.rent_fund.to_account_info(),
        message_transmitter: ctx.accounts.message_transmitter.to_account_info(),
        message_sent_event_data: ctx.accounts.message_sent_event_data.to_account_info(),
    };
    let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, rent_fund_seeds);
    message_transmitter_v2::cpi::reclaim_event_account(cpi_ctx, cctp_v2_params)?;

    emit_cpi!(ReclaimedEventAccount { message_sent_event_data: ctx.accounts.message_sent_event_data.key() });

    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(params: UsedNonceAccountParams)]
pub struct ReclaimUsedNonceAccount<'info> {
    #[account(seeds = [b"state"], bump = state.bump)]
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
    #[account(seeds = [b"state"], bump = state.bump)]
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
