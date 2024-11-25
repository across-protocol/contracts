use anchor_lang::{prelude::*, solana_program::system_program};

use crate::error::SvmError;

#[derive(Accounts)]
#[instruction(total_size: u32)]
pub struct InitializeInstructionParams<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    /// CHECK: We only allocate empty account here. Raw data will be written in separate instruction.
    #[account(
        init,
        payer = signer,
        space = total_size as usize,
        seeds = [b"instruction_params", signer.key().as_ref()],
        bump
    )]
    pub instruction_params: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(offset: u32, fragment: Vec<u8>)]
pub struct WriteInstructionParamsFragment<'info> {
    pub signer: Signer<'info>,

    /// CHECK: use unchecked account in order to be able writing raw data fragments.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump)]
    pub instruction_params: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn write_instruction_params_fragment(
    ctx: Context<WriteInstructionParamsFragment<'_>>,
    offset: u32,
    fragment: Vec<u8>,
) -> Result<()> {
    let account_info = ctx.accounts.instruction_params.to_account_info();

    let data = &mut account_info.try_borrow_mut_data()?;

    let start = offset as usize;
    let end = start + fragment.len();

    require!(end <= data.len(), SvmError::ParamsWriteOverflow);

    data[start..end].copy_from_slice(&fragment);

    Ok(())
}

#[derive(Accounts)]
pub struct CloseInstructionParams<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    /// CHECK: We cannot check account type as its discriminator could have been overwritten.
    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump)]
    pub instruction_params: UncheckedAccount<'info>,
}

// Reimplements close from anchor common module that is private. We cannot use anchor close constraint for unchecked accounts.
pub fn close_instruction_params(ctx: Context<CloseInstructionParams>) -> Result<()> {
    let closed_account = ctx.accounts.instruction_params.to_account_info();
    let sol_destination = ctx.accounts.signer.to_account_info();

    // Transfer tokens from the account to the sol_destination.
    let dest_starting_lamports = sol_destination.lamports();
    **sol_destination.lamports.borrow_mut() = dest_starting_lamports.checked_add(closed_account.lamports()).unwrap();
    **closed_account.lamports.borrow_mut() = 0;

    closed_account.assign(&system_program::ID);
    closed_account.realloc(0, false).map_err(Into::into)
}
