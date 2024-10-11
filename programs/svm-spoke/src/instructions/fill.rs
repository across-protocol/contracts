use anchor_lang::prelude::*;

use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::{
    constants::DISCRIMINATOR_SIZE,
    constraints::is_relay_hash_valid,
    error::CustomError,
    event::{FillType, FilledV3Relay, V3RelayExecutionEventInfo},
    state::{FillStatus, FillStatusAccount, State},
};

#[event_cpi]
#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct FillV3Relay<'info> {
    #[account(
        mut,
        seeds = [b"state", state.seed.to_le_bytes().as_ref()],
        bump,
        constraint = !state.paused_fills @ CustomError::FillsArePaused
    )]
    pub state: Account<'info, State>,

    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(mut)]
    pub relayer: SystemAccount<'info>,

    #[account(
        mut,
        address = relay_data.recipient @ CustomError::InvalidFillRecipient
    )]
    pub recipient: SystemAccount<'info>,

    #[account(
        mut,
        token::token_program = token_program,
        address = relay_data.output_token @ CustomError::InvalidMint
    )]
    pub mint_account: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = mint_account,
        associated_token::authority = relayer,
        associated_token::token_program = token_program
    )]
    pub relayer_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        associated_token::mint = mint_account,
        associated_token::authority = recipient,
        associated_token::token_program = token_program
    )]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        // Make sure caller provided relay_hash used in PDA seeds is valid.
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ CustomError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V3RelayData {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub exclusive_relayer: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub origin_chain_id: u64,
    pub deposit_id: u32,
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub message: Vec<u8>,
}

pub fn fill_v3_relay(
    ctx: Context<FillV3Relay>,
    relay_hash: [u8; 32], // include in props, while not using it, to enable us to access it from the #Instruction Attribute within the accounts. This enables us to pass in the relay_hash PDA.
    relay_data: V3RelayData,
    repayment_chain_id: u64,
    repayment_address: Pubkey,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    // TODO: Try again to pull this into a helper function. for some reason I was not able to due to passing context around of state.
    let current_time = if state.current_time != 0 {
        state.current_time
    } else {
        Clock::get()?.unix_timestamp as u32
    };

    // Check the fill status
    let fill_status_account = &mut ctx.accounts.fill_status;
    require!(
        fill_status_account.status != FillStatus::Filled,
        CustomError::RelayFilled
    );

    // Check if the fill deadline has passed
    require!(
        current_time <= relay_data.fill_deadline,
        CustomError::ExpiredFillDeadline
    );

    // Check if the exclusivity deadline has passed or if the caller is the exclusive relayer
    if relay_data.exclusive_relayer != Pubkey::default() {
        require!(
            current_time > relay_data.exclusivity_deadline
                || ctx.accounts.signer.key() == relay_data.exclusive_relayer,
            CustomError::NotExclusiveRelayer
        );
    }

    // Invoke the transfer_checked instruction on the token program
    let transfer_accounts = TransferChecked {
        from: ctx.accounts.relayer_token_account.to_account_info(),
        mint: ctx.accounts.mint_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.signer.to_account_info(),
    };
    let cpi_context = CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        transfer_accounts,
    );
    transfer_checked(
        cpi_context,
        relay_data.output_amount,
        ctx.accounts.mint_account.decimals,
    )?;

    // Update the fill status to Filled and set the relayer
    fill_status_account.status = FillStatus::Filled;
    fill_status_account.relayer = *ctx.accounts.signer.key;

    msg!("Tokens transferred successfully.");

    // Emit the FilledV3Relay event
    let message_clone = relay_data.message.clone(); // Clone the message before it is moved

    emit_cpi!(FilledV3Relay {
        input_token: relay_data.input_token,
        output_token: relay_data.output_token,
        input_amount: relay_data.input_amount,
        output_amount: relay_data.output_amount,
        repayment_chain_id,
        repayment_address,
        origin_chain_id: relay_data.origin_chain_id,
        deposit_id: relay_data.deposit_id,
        fill_deadline: relay_data.fill_deadline,
        exclusivity_deadline: relay_data.exclusivity_deadline,
        exclusive_relayer: relay_data.exclusive_relayer,
        relayer: *ctx.accounts.signer.key,
        depositor: relay_data.depositor,
        recipient: relay_data.recipient,
        message: relay_data.message,
        relay_execution_info: V3RelayExecutionEventInfo {
            updated_recipient: relay_data.recipient,
            updated_message: message_clone,
            updated_output_amount: relay_data.output_amount,
            fill_type: FillType::FastFill,
        },
    });

    Ok(())
}

#[derive(Accounts)]
#[instruction(relay_hash: [u8; 32], relay_data: V3RelayData)]
pub struct CloseFillPda<'info> {
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        mut,
        address = fill_status.relayer @ CustomError::NotRelayer
    )]
    pub signer: Signer<'info>,

    #[account(
        mut,
        seeds = [b"fills", relay_hash.as_ref()],
        bump,
        close = signer,
        // Make sure caller provided relay_hash used in PDA seeds is valid.
        constraint = is_relay_hash_valid(&relay_hash, &relay_data, &state) @ CustomError::InvalidRelayHash
    )]
    pub fill_status: Account<'info, FillStatusAccount>,
}

pub fn close_fill_pda(
    ctx: Context<CloseFillPda>,
    relay_hash: [u8; 32],
    relay_data: V3RelayData,
) -> Result<()> {
    let state = &mut ctx.accounts.state;
    // TODO: Try again to pull this into a helper function. for some reason I was not able to due to passing context around of state.
    let current_time = if state.current_time != 0 {
        state.current_time
    } else {
        Clock::get()?.unix_timestamp as u32
    };

    // Check if the fill status is filled
    require!(
        ctx.accounts.fill_status.status == FillStatus::Filled,
        CustomError::NotFilled
    );

    // Check if the deposit has expired
    require!(
        current_time > relay_data.fill_deadline,
        CustomError::FillDeadlineNotPassed
    );

    Ok(())
}

// Events.
