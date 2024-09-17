use anchor_lang::prelude::*;

declare_id!("E4dpZS9P24pscXvPngpeUhrR98uZYMfi3VMLnLaYDA6b");

#[program]
pub mod testacross {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}
