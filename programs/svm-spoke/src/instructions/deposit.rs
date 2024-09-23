use anchor_lang::prelude::*;

use crate::{
    error::CustomError,
    state::{Route, State},
};

use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
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
    destination_chain_id: u64,
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

    #[account(mut, seeds = [b"route", input_token.as_ref(), destination_chain_id.to_le_bytes().as_ref()], bump)]
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

    // TODO: I'm not totally sure how the check here is sufficient. For example can an account make their own fake
    // spoke pool, create a route PDA, toggle it to enabled and then call deposit, passing in that PDA and
    // enable a deposit to occur against a route that was not canonically enabled? write some tests for this and
    // verify that this check is sufficient or update accordingly.
    require!(ctx.accounts.route.enabled, CustomError::DisabledRoute);

    let current_time = if state.current_time != 0 {
        state.current_time
    } else {
        Clock::get()?.unix_timestamp as u32
    };

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

#[event]
pub struct V3FundsDeposited {
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub destination_chain_id: u64,
    pub deposit_id: u64,
    pub quote_timestamp: u32,
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub exclusive_relayer: Pubkey,
    pub message: Vec<u8>,
}
