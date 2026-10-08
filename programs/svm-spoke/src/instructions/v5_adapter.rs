use anchor_lang::prelude::*;

use crate::{
    state::State,
    v5::{
        accounts::require_gateway_dispatch_authority,
        codec::{decode_v5_adapter_input, GatewayContextV1, V5AdapterInput},
    },
};

mod deposit;
mod fill;
mod token;

use deposit::execute_v5_deposit;
use fill::execute_v5_fill;

#[event_cpi]
#[derive(Accounts)]
pub struct AdapterExecuteAcrossV5<'info> {
    /// CHECK: Must be the live Gateway PDA for this program and must sign the CPI.
    pub dispatch_authority: UncheckedAccount<'info>,

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,
}

pub fn adapter_execute_across_v5<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: GatewayContextV1,
    input: Vec<u8>,
    jit_data: Vec<u8>,
) -> Result<()> {
    require_gateway_dispatch_authority(&ctx.accounts.dispatch_authority)?;
    match decode_v5_adapter_input(&input)? {
        V5AdapterInput::DepositV1(deposit) => execute_v5_deposit(ctx, ctx_values, deposit, &jit_data),
        V5AdapterInput::FillV1(fill_input) => execute_v5_fill(ctx, ctx_values, fill_input, &jit_data),
    }
}
