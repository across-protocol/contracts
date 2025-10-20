use anchor_lang::prelude::*;

declare_id!("3xGkdXunLALbrKxuouchngkUpThU2oyNjJpBECV4bkEC");

// External programs from idls directory (requires anchor run generateExternalTypes).
declare_program!(message_transmitter_v2);
declare_program!(token_messenger_minter_v2);

pub mod error;
pub mod event;
mod instructions;
pub mod state;
pub mod utils;

pub use error::*;
pub use event::*;
use instructions::*;
pub use state::*;
use utils::*;

#[program]
pub mod sponsored_cctp_src_periphery {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, params: InitializeParams) -> Result<()> {
        instructions::initialize(ctx, &params)
    }

    pub fn set_signer(ctx: Context<SetSigner>, params: SetSignerParams) -> Result<()> {
        instructions::set_signer(ctx, &params)
    }

    pub fn withdraw_rent_fund(ctx: Context<WithdrawRentFund>, params: WithdrawRentFundParams) -> Result<()> {
        instructions::withdraw_rent_fund(ctx, &params)
    }

    pub fn deposit(ctx: Context<Deposit>, params: DepositParams) -> Result<()> {
        instructions::deposit(ctx, &params)
    }

    pub fn reclaim_event_account(ctx: Context<ReclaimEventAccount>, params: ReclaimEventAccountParams) -> Result<()> {
        instructions::reclaim_event_account(ctx, &params)
    }

    pub fn reclaim_used_nonce_account(
        ctx: Context<ReclaimUsedNonceAccount>,
        params: UsedNonceAccountParams,
    ) -> Result<()> {
        instructions::reclaim_used_nonce_account(ctx, &params)
    }

    pub fn set_current_time(ctx: Context<SetCurrentTime>, params: SetCurrentTimeParams) -> Result<()> {
        utils::set_current_time(ctx, params)
    }

    pub fn get_used_nonce_close_info(
        ctx: Context<GetUsedNonceCloseInfo>,
        _params: UsedNonceAccountParams,
    ) -> Result<UsedNonceCloseInfo> {
        instructions::get_used_nonce_close_info(ctx)
    }
}
