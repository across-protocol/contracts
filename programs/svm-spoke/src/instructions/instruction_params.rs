use anchor_lang::{prelude::*, solana_program::system_program};

use crate::error::SvmError;

#[derive(Accounts)]
#[instruction(total_size: u32)]
pub struct InitializeInstructionParams<'info> {
    /// Signer responsible for funding the initialization of the account.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// CHECK: The account is initialized as empty, and raw data will be written later.
    #[account(
        init,
        payer = signer,
        space = total_size as usize,
        seeds = [b"instruction_params", signer.key().as_ref()],
        bump
    )]
    pub instruction_params: UncheckedAccount<'info>,

    /// System program required for account initialization.
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(offset: u32, fragment: Vec<u8>)]
pub struct WriteInstructionParamsFragment<'info> {
    /// Signer responsible for authorizing the write operation.
    pub signer: Signer<'info>,

    /// CHECK: The account is mutable to allow raw data writing.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump)]
    pub instruction_params: UncheckedAccount<'info>,

    /// System program required for any additional operations.
    pub system_program: Program<'info, System>,
}

/// Writes a fragment of raw data into the `instruction_params` account at the specified offset.
///
/// ### Parameters:
/// - `ctx`: The context for the write operation.
/// - `offset`: The starting position in the account's data where the fragment will be written.
/// - `fragment`: The raw data to write into the account.
pub fn write_instruction_params_fragment<'info>(
    ctx: Context<WriteInstructionParamsFragment<'info>>,
    offset: u32,
    fragment: Vec<u8>,
) -> Result<()> {
    let account_info = ctx.accounts.instruction_params.to_account_info();

    // Access the mutable data buffer of the account.
    let data = &mut account_info.try_borrow_mut_data()?;

    let start = offset as usize;
    let end = start + fragment.len();

    // Ensure the write operation does not overflow the account's data buffer.
    require!(end <= data.len(), SvmError::ParamsWriteOverflow);

    // Write the fragment into the specified range of the account's data.
    data[start..end].copy_from_slice(&fragment);

    Ok(())
}

#[derive(Accounts)]
pub struct CloseInstructionParams<'info> {
    /// Signer responsible for closing the account and receiving the SOL.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// CHECK: The account is mutable to allow lamports transfer and account closure.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump)]
    pub instruction_params: UncheckedAccount<'info>,
}

/// Closes the `instruction_params` account and transfers its SOL to the signer.
///
/// ### Parameters:
/// - `ctx`: The context for the close operation.
pub fn close_instruction_params(ctx: Context<CloseInstructionParams>) -> Result<()> {
    let closed_account = ctx.accounts.instruction_params.to_account_info();
    let sol_destination = ctx.accounts.signer.to_account_info();

    // Transfer lamports from the closed account to the destination account.
    let dest_starting_lamports = sol_destination.lamports();
    **sol_destination.lamports.borrow_mut() = dest_starting_lamports
        .checked_add(closed_account.lamports())
        .ok_or(SvmError::LamportsOverflow)?;
    **closed_account.lamports.borrow_mut() = 0;

    // Assign the closed account to the system program and reallocate it to zero space.
    closed_account.assign(&system_program::ID);
    closed_account.realloc(0, false).map_err(Into::into)
}
