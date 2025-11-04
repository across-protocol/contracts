use anchor_lang::prelude::*;

use crate::state::State;

#[derive(Accounts)]
pub struct SetCurrentTime<'info> {
    #[account(mut, seeds = [b"state"], bump)]
    pub state: Account<'info, State>,

    pub signer: Signer<'info>,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SetCurrentTimeParams {
    pub new_time: u64,
}

pub fn set_current_time(ctx: Context<SetCurrentTime>, _params: SetCurrentTimeParams) -> Result<()> {
    let _state = &mut ctx.accounts.state;

    #[cfg(not(feature = "test"))]
    {
        err!(crate::error::SvmError::CannotSetCurrentTime)
    }

    #[cfg(feature = "test")]
    {
        _state.current_time = _params.new_time;
        Ok(())
    }
}

pub fn initialize_current_time(_state: &mut State) -> Result<()> {
    #[cfg(feature = "test")]
    {
        _state.current_time = u64::try_from(Clock::get()?.unix_timestamp)?;
    }

    Ok(())
}

pub fn get_current_time(_state: &State) -> Result<u64> {
    #[cfg(not(feature = "test"))]
    {
        Ok(u64::try_from(Clock::get()?.unix_timestamp)?)
    }

    #[cfg(feature = "test")]
    {
        Ok(_state.current_time)
    }
}
