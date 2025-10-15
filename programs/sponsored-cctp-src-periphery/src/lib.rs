use anchor_lang::prelude::*;

declare_id!("3xGkdXunLALbrKxuouchngkUpThU2oyNjJpBECV4bkEC");

// External programs from idls directory (requires anchor run generateExternalTypes).
declare_program!(message_transmitter_v2);
declare_program!(token_messenger_minter_v2);

pub mod constants;
pub mod error;
pub mod event;
mod instructions;
pub mod state;
pub mod utils;

pub use constants::*;
pub use error::*;
pub use event::*;
use instructions::*;
pub use state::*;

#[program]
pub mod sponsored_cctp_src_periphery {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, seed: u64) -> Result<()> {
        instructions::initialize(ctx, seed)
    }

    pub fn deposit(ctx: Context<Deposit>, params: DepositParams) -> Result<()> {
        instructions::deposit(ctx, &params)
    }
}
