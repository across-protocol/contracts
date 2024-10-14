use anchor_lang::prelude::*;

declare_id!("95JnB8NmS5cqxJ9TFLdZPJzPZYkrtaPYMGvEmszY1TLn");

#[program]
pub mod across_message_handler {
    use super::*;

    pub fn handle_v3_across_message(ctx: Context<Initialize>,output_token:Pubkey,amountToSend:u64,relayer:Pubkey,message:Vec<u8>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}
