use anchor_lang::{
    prelude::*,
    solana_program::{
        instruction::Instruction,
        program::{invoke, invoke_signed},
    },
};

declare_id!("6kqWTz3A3ZYMV2FMU24ke8rHzT82SaBz7GkBKTd7Z9BH");

#[program]
pub mod multicall_handler {
    use super::*;

    // Handler to receive AcrossV3 message formatted as serialized message compiled instructions. When deserialized,
    // these are matched with the passed accounts and executed as CPIs.
    pub fn handle_v3_across_message(ctx: Context<HandleV3AcrossMessage>, message: Vec<u8>) -> Result<()> {
        // Some instructions might require being signed by handler PDA.
        let (handler_signer, bump) = Pubkey::find_program_address(&[b"handler_signer"], &crate::ID);
        let mut use_handler_signer = false;

        let compiled_ixs: Vec<CompiledIx> = AnchorDeserialize::deserialize(&mut &message[..])?;

        for compiled_ix in compiled_ixs {
            let mut accounts = Vec::with_capacity(compiled_ix.account_key_indexes.len());
            let mut account_infos = Vec::with_capacity(compiled_ix.account_key_indexes.len());

            let target_program = ctx
                .remaining_accounts
                .get(compiled_ix.program_id_index as usize)
                .ok_or(ErrorCode::AccountNotEnoughKeys)?;

            // Resolve CPI accounts from indexed references to the remaining accounts.
            for index in compiled_ix.account_key_indexes {
                let account_info = ctx
                    .remaining_accounts
                    .get(index as usize)
                    .ok_or(ErrorCode::AccountNotEnoughKeys)?;
                let is_handler_signer = account_info.key() == handler_signer;
                use_handler_signer |= is_handler_signer;

                match account_info.is_writable {
                    true => accounts.push(AccountMeta::new(account_info.key(), is_handler_signer)),
                    false => accounts.push(AccountMeta::new_readonly(account_info.key(), is_handler_signer)),
                }
                account_infos.push(account_info.to_owned());
            }

            let cpi_instruction = Instruction { program_id: target_program.key(), accounts, data: compiled_ix.data };

            match use_handler_signer {
                true => invoke_signed(&cpi_instruction, &account_infos, &[&[b"handler_signer", &[bump]]])?,
                false => invoke(&cpi_instruction, &account_infos)?,
            }
        }

        Ok(())
    }
}

#[derive(AnchorDeserialize)]
pub struct CompiledIx {
    pub program_id_index: u8,
    pub account_key_indexes: Vec<u8>,
    pub data: Vec<u8>,
}

#[derive(Accounts)]
pub struct HandleV3AcrossMessage {}
