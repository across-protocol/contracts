use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::spl_token_2022::{
        extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
        state::Mint as SplMint,
    },
    token_interface::TokenAccount,
};

use crate::{
    error::V5Error,
    state::State,
    v5::{
        codec::{decode_v5_adapter_input, GatewayContextV1, V5AdapterInput},
        pda::require_gateway_dispatch_authority,
    },
};

mod deposit;
mod fill;

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

fn load_token_account(
    info: &AccountInfo,
    token_program: &Pubkey,
    mint: &Pubkey,
    authority: &Pubkey,
) -> Result<TokenAccount> {
    require_keys_eq!(*info.owner, *token_program, V5Error::InvalidTokenAccount);
    let account = TokenAccount::try_deserialize(&mut &info.try_borrow_data()?[..])
        .map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    require_keys_eq!(account.mint, *mint, V5Error::InvalidTokenAccount);
    require_keys_eq!(account.owner, *authority, V5Error::InvalidTokenAccount);
    Ok(account)
}

fn validate_v5_mint(info: &AccountInfo, token_program: &Pubkey) -> Result<u8> {
    let data = info.try_borrow_data()?;
    let mint = StateWithExtensions::<SplMint>::unpack(&data).map_err(|_| error!(V5Error::InvalidTokenAccount))?;
    if *token_program == anchor_spl::token_2022::ID {
        let extensions = mint
            .get_extension_types()
            .map_err(|_| error!(V5Error::InvalidTokenAccount))?;
        require!(extensions.iter().all(is_supported_v5_mint_extension), V5Error::UnsupportedTokenExtension);
    }
    Ok(mint.base.decimals)
}

fn is_supported_v5_mint_extension(extension: &ExtensionType) -> bool {
    matches!(
        extension,
        ExtensionType::MintCloseAuthority
            | ExtensionType::MetadataPointer
            | ExtensionType::TokenMetadata
            | ExtensionType::GroupPointer
            | ExtensionType::TokenGroup
            | ExtensionType::GroupMemberPointer
            | ExtensionType::TokenGroupMember
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_2022_mint_extension_allowlist_is_fail_closed() {
        assert!(is_supported_v5_mint_extension(&ExtensionType::MetadataPointer));
        assert!(is_supported_v5_mint_extension(&ExtensionType::MintCloseAuthority));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::TransferFeeConfig));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::TransferHook));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::PermanentDelegate));
        assert!(!is_supported_v5_mint_extension(&ExtensionType::DefaultAccountState));
    }
}
