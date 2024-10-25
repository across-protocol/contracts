use anchor_lang::prelude::*;

use crate::{ error::CustomError, state::State };

#[derive(Accounts)]
pub struct SetCurrentTime<'info> {
    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    pub signer: Signer<'info>,
}

pub fn set_current_time(ctx: Context<SetCurrentTime>, _new_time: u32) -> Result<()> {
    let _state = &mut ctx.accounts.state;

    #[cfg(not(feature = "test"))]
    {
        return err!(CustomError::CannotSetCurrentTime);
    }

    #[cfg(feature = "test")]
    {
        _state.current_time = _new_time;
        Ok(())
    }
}

pub fn initialize_current_time(_state: &mut State) -> Result<()> {
    #[cfg(feature = "test")]
    {
        _state.current_time = Clock::get()?.unix_timestamp as u32;
    }

    Ok(())
}

pub fn get_current_time(_state: &State) -> Result<u32> {
    #[cfg(not(feature = "test"))]
    {
        Ok(Clock::get()?.unix_timestamp as u32)
    }

    #[cfg(feature = "test")]
    {
        Ok(_state.current_time)
    }
}
