//! Transfers authorized by the V5 adapter's fixed deposit and fill delegates.

use crate::{
    constants::{
        V5_DEPOSIT_DELEGATE, V5_DEPOSIT_DELEGATE_BUMP, V5_DEPOSIT_DELEGATE_SEED, V5_FILL_DELEGATE,
        V5_FILL_DELEGATE_BUMP, V5_FILL_DELEGATE_SEED,
    },
    error::SvmError,
};
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{transfer_checked, TransferChecked};

/// Select a trusted address/seed/bump combination; callers cannot mix delegate components.
#[derive(Clone, Copy)]
pub(crate) enum V5TransferDelegate {
    Deposit,
    Fill,
}

impl V5TransferDelegate {
    const fn address(self) -> Pubkey {
        match self {
            Self::Deposit => V5_DEPOSIT_DELEGATE,
            Self::Fill => V5_FILL_DELEGATE,
        }
    }

    const fn signer_seeds(self) -> [&'static [u8]; 2] {
        match self {
            Self::Deposit => [V5_DEPOSIT_DELEGATE_SEED, &[V5_DEPOSIT_DELEGATE_BUMP]],
            Self::Fill => [V5_FILL_DELEGATE_SEED, &[V5_FILL_DELEGATE_BUMP]],
        }
    }
}

pub(crate) fn transfer_from<'info>(
    accounts: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    amount: u64,
    mint_decimals: u8,
    delegate: V5TransferDelegate,
) -> Result<()> {
    require_keys_eq!(accounts.authority.key(), delegate.address(), SvmError::InvalidDelegatePda);

    transfer_checked(
        CpiContext::new_with_signer(token_program.key(), accounts, &[&delegate.signer_seeds()]),
        amount,
        mint_decimals,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfer_delegate_variants_select_their_expected_pdas() {
        assert_eq!(V5TransferDelegate::Deposit.address(), V5_DEPOSIT_DELEGATE);
        assert_eq!(V5TransferDelegate::Fill.address(), V5_FILL_DELEGATE);
        assert_eq!(V5TransferDelegate::Deposit.signer_seeds(), [V5_DEPOSIT_DELEGATE_SEED, &[V5_DEPOSIT_DELEGATE_BUMP]]);
        assert_eq!(V5TransferDelegate::Fill.signer_seeds(), [V5_FILL_DELEGATE_SEED, &[V5_FILL_DELEGATE_BUMP]]);
    }

    #[test]
    fn wrong_transfer_authority_is_rejected_before_cpi() {
        for delegate in [V5TransferDelegate::Deposit, V5TransferDelegate::Fill] {
            // Include the other canonical delegate: a valid Spoke PDA is insufficient for the wrong operation.
            for authority in [Pubkey::new_unique(), V5_DEPOSIT_DELEGATE, V5_FILL_DELEGATE] {
                if authority == delegate.address() {
                    continue;
                }
                let mut lamports = 0;
                let owner = Pubkey::default();
                let info = AccountInfo::new(&authority, false, false, &mut lamports, &mut [], &owner, false);
                let accounts = TransferChecked {
                    from: info.clone(),
                    mint: info.clone(),
                    to: info.clone(),
                    authority: info.clone(),
                };
                assert_eq!(transfer_from(accounts, info, 1, 6, delegate), Err(error!(SvmError::InvalidDelegatePda)));
            }
        }
    }
}
