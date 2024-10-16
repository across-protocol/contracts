use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::{
    error::CustomError,
    event::V3FundsDeposited,
    get_current_time,
    state::{Route, State},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64, // TODO: we can remove some of these instructions props
    exclusive_relayer: Pubkey,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_deadline: u32,
    message: Vec<u8>
)]
pub struct DepositV3<'info> {
    #[account(
        mut,
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_deposits @ CustomError::DepositsArePaused
    )]
    pub state: Account<'info, State>,

    // TODO: linter to format this line
    #[account(mut, seeds = [b"route", input_token.as_ref(), state.key().as_ref(), destination_chain_id.to_le_bytes().as_ref()], bump)]
    pub route: Account<'info, Route>,

    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        mut,
        token::mint = mint,
        token::authority = signer,
        token::token_program = token_program
    )]
    pub user_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    // TODO: why are we using mint::token_program,token::token_program and associated_token::token_program?
    #[account(
        mut,
        mint::token_program = token_program,
        // IDL build fails when requiring `address = input_token` for mint, thus using a custom constraint.
        constraint = mint.key() == input_token @ CustomError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn deposit_v3(
    ctx: Context<DepositV3>,
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    quote_timestamp: u32,
    fill_deadline: u32,
    exclusivity_deadline: u32,
    message: Vec<u8>,
) -> Result<()> {
    let state = &mut ctx.accounts.state;

    require!(ctx.accounts.route.enabled, CustomError::DisabledRoute);

    let current_time = get_current_time(state)?;

    // TODO: if the deposit quote timestamp is bad it is possible to make this error with a subtraction
    // overflow (from devnet testing). add a test to re-create this and fix it such that the error is thrown,
    // not caught via overflow.
    if current_time - quote_timestamp > state.deposit_quote_time_buffer {
        return Err(CustomError::InvalidQuoteTimestamp.into());
    }

    if fill_deadline < current_time || fill_deadline > current_time + state.fill_deadline_buffer {
        return Err(CustomError::InvalidFillDeadline.into());
    }

    let transfer_accounts = TransferChecked {
        from: ctx.accounts.user_token_account.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.vault.to_account_info(),
        authority: ctx.accounts.signer.to_account_info(),
    };
    let cpi_context = CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        transfer_accounts,
    );
    transfer_checked(cpi_context, input_amount, ctx.accounts.mint.decimals)?;

    state.number_of_deposits += 1; // Increment number of deposits

    emit_cpi!(V3FundsDeposited {
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        deposit_id: state.number_of_deposits,
        quote_timestamp,
        fill_deadline,
        exclusivity_deadline,
        depositor,
        recipient,
        exclusive_relayer,
        message,
    });

    Ok(())
}

// TODO: do we need other flavours of deposit? like speed up deposit
