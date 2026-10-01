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
    fn pda(self) -> (Pubkey, &'static [u8], u8) {
        match self {
            Self::Deposit => (V5_DEPOSIT_DELEGATE, V5_DEPOSIT_DELEGATE_SEED, V5_DEPOSIT_DELEGATE_BUMP),
            Self::Fill => (V5_FILL_DELEGATE, V5_FILL_DELEGATE_SEED, V5_FILL_DELEGATE_BUMP),
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
    let (delegate, delegate_seed, bump) = delegate.pda();
    if delegate != accounts.authority.key() {
        return err!(SvmError::InvalidDelegatePda);
    }

    let bump_seed = [bump];
    let signer_seeds: &[&[u8]] = &[delegate_seed, &bump_seed];
    let signer_seeds = [signer_seeds];

    transfer_checked(CpiContext::new_with_signer(token_program, accounts, &signer_seeds), amount, mint_decimals)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfer_delegate_variants_select_their_expected_pdas() {
        assert_eq!(
            V5TransferDelegate::Deposit.pda(),
            (V5_DEPOSIT_DELEGATE, V5_DEPOSIT_DELEGATE_SEED, V5_DEPOSIT_DELEGATE_BUMP)
        );
        assert_eq!(V5TransferDelegate::Fill.pda(), (V5_FILL_DELEGATE, V5_FILL_DELEGATE_SEED, V5_FILL_DELEGATE_BUMP));
    }

    #[test]
    fn wrong_transfer_authority_is_rejected_before_cpi() {
        for delegate in [V5TransferDelegate::Deposit, V5TransferDelegate::Fill] {
            // Include the other canonical delegate: a valid Spoke PDA is insufficient for the wrong operation.
            for authority in [Pubkey::new_unique(), V5_DEPOSIT_DELEGATE, V5_FILL_DELEGATE] {
                if authority == delegate.pda().0 {
                    continue;
                }
                let mut lamports = 0;
                let owner = Pubkey::default();
                let info = AccountInfo::new(&authority, false, false, &mut lamports, &mut [], &owner, false, 0);
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
