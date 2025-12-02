use anchor_lang::{prelude::*, system_program};
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::{
    error::{CommonError, SvmError},
    event::{AccruedRentFundLiability, CreatedEventAccount, SponsoredDepositForBurn},
    message_transmitter_v2::{accounts::MessageSent, program::MessageTransmitterV2},
    state::{MessageSentSpace, MinimumDeposit, RentClaim, State, UsedNonce},
    token_messenger_minter_v2::{
        self, cpi::accounts::DepositForBurnWithHook, program::TokenMessengerMinterV2,
        types::DepositForBurnWithHookParams,
    },
    utils::{get_current_time, validate_signature, SponsoredCCTPQuote, QUOTE_SIGNATURE_LENGTH},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(params: DepositForBurnParams)]
pub struct DepositForBurn<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(seeds = [b"state"], bump = state.bump)]
    pub state: Account<'info, State>,

    #[account(mut, seeds = [b"rent_fund"], bump)]
    pub rent_fund: SystemAccount<'info>,

    #[account(seeds = [b"minimum_deposit", burn_token.key().as_ref()], bump = minimum_deposit.bump)]
    pub minimum_deposit: Account<'info, MinimumDeposit>,

    #[account(
        init, // Enforces that a given quote nonce can be used only once during the quote deadline.
        payer = signer,
        space = UsedNonce::space(),
        seeds = [b"used_nonce", params.quote.nonce.as_ref()],
        bump
    )]
    pub used_nonce: Account<'info, UsedNonce>,

    // Optional account passed to avoid reverts on insufficient rent_fund balance and accrue liability to the user.
    #[account(
        init_if_needed,
        payer = signer,
        space = RentClaim::DISCRIMINATOR.len() + RentClaim::INIT_SPACE,
        seeds = [b"rent_claim", signer.key().as_ref()],
        bump
    )]
    pub rent_claim: Option<Account<'info, RentClaim>>,

    #[account(
        mut,
        associated_token::mint = burn_token,
        associated_token::authority = signer,
        associated_token::token_program = token_program
    )]
    pub depositor_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        address = params.quote.burn_token @ SvmError::InvalidBurnToken,
        mint::token_program = token_program,
    )]
    pub burn_token: InterfaceAccount<'info, Mint>,

    /// CHECK: denylist PDA, checked in CCTP. Seeds must be ["denylist_account", signer.key()] (CCTP
    // TokenMessengerMinterV2 program).
    pub denylist_account: UncheckedAccount<'info>,

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
pub struct DepositForBurnParams {
    pub quote: SponsoredCCTPQuote,
    pub signature: [u8; QUOTE_SIGNATURE_LENGTH],
}

pub fn deposit_for_burn(mut ctx: Context<DepositForBurn>, params: &DepositForBurnParams) -> Result<()> {
    let quote = &params.quote;
    finance_accounts_creation(&mut ctx, quote)?;

    let state = &ctx.accounts.state;
    validate_signature(state.signer, &quote, &params.signature)?;

    if quote.deadline < get_current_time(state)? {
        return err!(CommonError::InvalidDeadline);
    }
    if quote.source_domain != state.source_domain {
        return err!(CommonError::InvalidSourceDomain);
    }
    if quote.amount < ctx.accounts.minimum_deposit.amount {
        return err!(SvmError::DepositAmountBelowMinimum);
    }

    // Record the quote deadline as it should be safe to close the used_nonce account after this time.
    ctx.accounts.used_nonce.quote_deadline = quote.deadline;

    // Invoke CCTPv2 to bridge user tokens. This burns user tokens directly by inheriting the signer privileges. The
    // side effect is that the user signer address will show up as messageSender on the destination chain, not the
    // authority of this program. This is still acceptable in the current flow where SponsoredCCTPDstPeriphery contract
    // on the destination chain revalidates the quote signature.
    let cpi_program = ctx.accounts.token_messenger_minter_program.to_account_info();
    let cpi_accounts = DepositForBurnWithHook {
        owner: ctx.accounts.signer.to_account_info(),
        event_rent_payer: ctx.accounts.rent_fund.to_account_info(),
        sender_authority_pda: ctx.accounts.token_messenger_minter_sender_authority.to_account_info(),
        burn_token_account: ctx.accounts.depositor_token_account.to_account_info(),
        denylist_account: ctx.accounts.denylist_account.to_account_info(),
        message_transmitter: ctx.accounts.message_transmitter.to_account_info(),
        token_messenger: ctx.accounts.token_messenger.to_account_info(),
        remote_token_messenger: ctx.accounts.remote_token_messenger.to_account_info(),
        token_minter: ctx.accounts.token_minter.to_account_info(),
        local_token: ctx.accounts.local_token.to_account_info(),
        burn_token_mint: ctx.accounts.burn_token.to_account_info(),
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
        amount: quote.amount,
        destination_domain: quote.destination_domain,
        mint_recipient: quote.mint_recipient,
        destination_caller: quote.destination_caller,
        max_fee: quote.max_fee,
        min_finality_threshold: quote.min_finality_threshold,
        hook_data: quote.encode_hook_data(),
    };
    token_messenger_minter_v2::cpi::deposit_for_burn_with_hook(cpi_ctx, cpi_params)?;

    emit_cpi!(SponsoredDepositForBurn {
        quote_nonce: quote.nonce.to_vec(),
        origin_sender: ctx.accounts.signer.key(),
        final_recipient: quote.final_recipient,
        quote_deadline: quote.deadline,
        max_bps_to_sponsor: quote.max_bps_to_sponsor,
        max_user_slippage_bps: quote.max_user_slippage_bps,
        final_token: quote.final_token,
        signature: params.signature.to_vec(),
    });

    emit_cpi!(CreatedEventAccount { message_sent_event_data: ctx.accounts.message_sent_event_data.key() });

    // Close the claim account if the user passed Some rent_claim account without accruing any rent_fund debt.
    if let Some(rent_claim) = &ctx.accounts.rent_claim {
        if rent_claim.amount == 0 {
            rent_claim.close(ctx.accounts.signer.to_account_info())?;
        }
    }

    Ok(())
}

fn finance_accounts_creation(ctx: &mut Context<DepositForBurn>, quote: &SponsoredCCTPQuote) -> Result<()> {
    let anchor_rent = Rent::get()?;

    // User already has paid for the UsedNonce account creation in DepositForBurn account constraints that should be
    // reimbursed from the rent_fund. Actual cost for the user might have been lower if somebody had pre-funded the
    // UsedNonce account, but that should be of no concern as the rent_fund account will receive the whole balance upon
    // its closure.
    let mut debt_to_user = anchor_rent.minimum_balance(UsedNonce::space());

    // rent_fund will need to pay for the MessageSent account creation and ensure itself will have enough balance for
    // being rent-exempt. We don't attempt targeting rent_fund balance exactly to 0 just to keep the accounting simpler
    // and borrow any extra amount from the user instead.
    let needed_in_rent_fund = anchor_rent
        .minimum_balance(MessageSent::space(quote))
        .saturating_sub(ctx.accounts.message_sent_event_data.lamports())
        .saturating_add(anchor_rent.minimum_balance(0));

    let rent_fund_balance = ctx.accounts.rent_fund.lamports();

    let (transfer_to_user, transfer_from_user) = if rent_fund_balance >= needed_in_rent_fund {
        // Get transfer amount to the user for the UsedNonce account creation ensuring that the rent_fund will still
        // have enough balance for MessageSent account creation and being rent-exempt.
        let transfer_to_user = debt_to_user.min(rent_fund_balance - needed_in_rent_fund);
        debt_to_user -= transfer_to_user;

        (transfer_to_user, 0)
    } else {
        // Get transfer amount from the user to borrow for the MessageSent account creation and being rent-exempt.
        let transfer_from_user = needed_in_rent_fund - rent_fund_balance;
        debt_to_user += transfer_from_user;

        (0, transfer_from_user)
    };
    // Note: we don't perform any checks on the signer balance and if it would be rent-exempt as the user might have
    // appended any other spending instructions that would invalidate any rent-exempt invariants checked here. It is the
    // responsibility of the user to have sufficiently funded signer and it is expected that their wallet software would
    // simulate the transaction before sending it to the network.

    // Record and emit any non-zero debt to the user that should be reimbursed later. This requires having Some
    // rent_claim account provided.
    if debt_to_user > 0 {
        let Some(rent_claim) = ctx.accounts.rent_claim.as_mut() else {
            return err!(SvmError::MissingRentClaimAccount);
        };

        rent_claim.amount = match rent_claim.amount.checked_add(debt_to_user) {
            Some(v) => v,
            None => {
                return err!(SvmError::RentClaimOverflow);
            }
        };

        emit_cpi!(AccruedRentFundLiability {
            user: ctx.accounts.signer.key(),
            amount: debt_to_user,
            total_user_claim: rent_claim.amount,
        });
    }

    if transfer_to_user > 0 {
        let cpi_accounts = system_program::Transfer {
            from: ctx.accounts.rent_fund.to_account_info(),
            to: ctx.accounts.signer.to_account_info(),
        };
        let rent_fund_seeds: &[&[&[u8]]] = &[&[b"rent_fund", &[ctx.bumps.rent_fund]]];
        let cpi_context =
            CpiContext::new_with_signer(ctx.accounts.system_program.to_account_info(), cpi_accounts, rent_fund_seeds);
        system_program::transfer(cpi_context, transfer_to_user)?;
    }

    if transfer_from_user > 0 {
        let cpi_accounts = system_program::Transfer {
            from: ctx.accounts.signer.to_account_info(),
            to: ctx.accounts.rent_fund.to_account_info(),
        };
        let cpi_context = CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
        system_program::transfer(cpi_context, transfer_from_user)?;
    }

    Ok(())
}
