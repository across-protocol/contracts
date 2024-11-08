use anchor_lang::{
    prelude::*,
    solana_program::{
        instruction::Instruction,
        program::{invoke, invoke_signed},
    },
};

declare_id!("6zbEkDZGuHqGiACGWc2Xd5DY4m52qwXjmthzWtnoCTyG");

#[program]
pub mod multicall_handler {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }

    pub fn handle_v3_across_message(ctx: Context<HandleV3AcrossMessage>, message: Vec<u8>) -> Result<()> {
        let (pda_signer, bump) = Pubkey::find_program_address(&[b"pda_signer"], &crate::ID);
        let mut use_pda_signer = false;

        let calls: Vec<Call> = AnchorDeserialize::deserialize(&mut &message[..])?;

        for call in calls {
            let mut accounts = Vec::with_capacity(call.account_indexes.len());
            let mut account_infos = Vec::with_capacity(call.account_indexes.len());

            let target_program = ctx
                .remaining_accounts
                .get(call.program_index as usize)
                .ok_or(ErrorCode::AccountNotEnoughKeys)?;

            for i in call.account_indexes {
                let acc = ctx
                    .remaining_accounts
                    .get(i as usize)
                    .ok_or(ErrorCode::AccountNotEnoughKeys)?;
                let is_pda_signer = acc.key() == pda_signer;
                use_pda_signer |= is_pda_signer;
                if acc.is_writable {
                    accounts.push(AccountMeta::new(acc.key(), acc.is_signer || is_pda_signer));
                } else {
                    accounts.push(AccountMeta::new_readonly(acc.key(), acc.is_signer || is_pda_signer));
                }
                account_infos.push(acc.to_owned());
            }

            let instruction = Instruction {
                program_id: target_program.key(),
                accounts,
                data: call.data,
            };

            match use_pda_signer {
                true => invoke_signed(&instruction, &account_infos, &[&[b"pda_signer", &[bump]]])?,
                false => invoke(&instruction, &account_infos)?,
            }
        }

        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}

#[derive(AnchorDeserialize, AnchorSerialize)]
pub struct Call {
    pub program_index: u8,
    pub account_indexes: Vec<u8>,
    pub data: Vec<u8>,
}

#[derive(Accounts)]
pub struct HandleV3AcrossMessage {}
