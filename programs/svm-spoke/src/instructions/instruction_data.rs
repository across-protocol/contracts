use anchor_lang::{
    prelude::*,
    solana_program::{instruction::Instruction, program},
};

use crate::{constants::DISCRIMINATOR_SIZE, program::SvmSpoke, InstructionData};

#[derive(Accounts)]
#[instruction(total_size: u32)]
pub struct InitializeInstructionData<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        init,
        payer = signer,
        space = DISCRIMINATOR_SIZE + InstructionData::INIT_SPACE + total_size as usize,
        seeds = [b"instruction_data", signer.key().as_ref()],
        bump
    )]
    pub instruction_data: Account<'info, InstructionData>,

    pub system_program: Program<'info, System>,
}

pub fn initialize_instruction_data(
    ctx: Context<InitializeInstructionData>,
    total_size: u32,
) -> Result<()> {
    ctx.accounts.instruction_data.data = vec![0; total_size as usize];

    Ok(())
}

#[derive(Accounts)]
pub struct WriteInstructionDataFragment<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        mut,
        seeds = [b"instruction_data", signer.key().as_ref()],
        bump
    )]
    pub instruction_data: Account<'info, InstructionData>,
}

pub fn write_instruction_data_fragment(
    ctx: Context<WriteInstructionDataFragment>,
    offset: u32,
    fragment: Vec<u8>,
) -> Result<()> {
    let instruction_data = &mut ctx.accounts.instruction_data;

    let offset = offset as usize;
    instruction_data.data[offset..offset + fragment.len()].copy_from_slice(&fragment);

    Ok(())
}

#[derive(Accounts)]
pub struct CallWithInstructionData<'info> {
    pub instruction_data: Account<'info, InstructionData>,

    pub program: Program<'info, SvmSpoke>,
}

pub fn call_with_instruction_data(ctx: Context<CallWithInstructionData>) -> Result<()> {
    let mut accounts = Vec::with_capacity(ctx.remaining_accounts.len());
    for acc in ctx.remaining_accounts {
        if acc.is_writable {
            accounts.push(AccountMeta::new(acc.key(), acc.is_signer));
        } else {
            accounts.push(AccountMeta::new_readonly(acc.key(), acc.is_signer));
        }
    }
    let instruction = Instruction {
        program_id: crate::ID,
        accounts,
        data: ctx.accounts.instruction_data.data.clone(),
    };
    program::invoke(&instruction, &ctx.remaining_accounts)?;

    Ok(())
}

#[derive(Accounts)]
pub struct CloseInstructionData<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        mut,
        close = signer,
        seeds = [b"instruction_data", signer.key().as_ref()],
        bump,
    )]
    pub instruction_data: Account<'info, InstructionData>,
}

pub fn close_instruction_data() -> Result<()> {
    Ok(())
}
