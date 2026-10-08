use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_2022::spl_token_2022::{
        extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions},
        state::Mint as SplMint,
    },
    token_interface::TokenAccount,
};

use crate::{constants::GATEWAY_VAULT_AUTHORITY, error::V5Error, v5::accounts::find_v5_account};

/// Validated mint, token program, and canonical Gateway vault shared by deposits and fills.
pub(super) struct V5TokenAccounts<'info> {
    pub token_program: AccountInfo<'info>,
    pub mint: AccountInfo<'info>,
    pub mint_decimals: u8,
    pub gateway_vault: AccountInfo<'info>,
    pub gateway_vault_balance: u64,
}

impl<'info> V5TokenAccounts<'info> {
    pub fn load(remaining_accounts: &[AccountInfo<'info>], mint: &Pubkey) -> Result<Self> {
        let mint_info = find_v5_account(remaining_accounts, mint, false)?;
        let token_program_id = *mint_info.owner;
        // Match Interface<TokenInterface>'s supported token-program IDs.
        require!(
            token_program_id == anchor_spl::token::ID || token_program_id == anchor_spl::token_2022::ID,
            V5Error::InvalidTokenAccount
        );
        let token_program = find_v5_account(remaining_accounts, &token_program_id, false)?;
        let mint_decimals = validate_v5_mint(mint_info, &token_program_id)?;

        // Canonical ATA derivation plus owner, mint, and authority checks mirror Anchor's associated-token constraints.
        let gateway_vault =
            get_associated_token_address_with_program_id(&GATEWAY_VAULT_AUTHORITY, mint, &token_program_id);
        let gateway_vault_info = find_v5_account(remaining_accounts, &gateway_vault, true)?;
        let gateway_vault_account =
            load_token_account(gateway_vault_info, &token_program_id, mint, &GATEWAY_VAULT_AUTHORITY)?;

        Ok(Self {
            token_program: token_program.clone(),
            mint: mint_info.clone(),
            mint_decimals,
            gateway_vault: gateway_vault_info.clone(),
            gateway_vault_balance: gateway_vault_account.amount,
        })
    }
}

pub(super) fn load_token_account(
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
