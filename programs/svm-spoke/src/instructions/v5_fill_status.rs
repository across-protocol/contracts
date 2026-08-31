use anchor_lang::{
    prelude::*,
    solana_program::{program::invoke_signed, system_instruction, system_program},
};

use crate::{
    constants::{DISCRIMINATOR_SIZE, FILL_STATUS_SEED, V5_FILL_PAYER_SEED},
    error::{CommonError, V5Error},
    event::V5FillFloatWithdrawn,
    state::{FillStatus, FillStatusAccount},
    ID,
};

pub const V5_FILL_STATUS_SPACE: usize = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE;

/// Creates and records a V5 fill status using program-derived signers only. Gateway does not forward the transaction
/// signer to adapter callees, so the submitter-scoped payer float funds the standard fill-status PDA. Storing the payer
/// PDA in the existing `relayer` slot binds permissionless expiry reclaim to the correct float without changing the
/// account layout; legacy fills continue to store their signing relayer there.
#[allow(dead_code)] // Called when Step 4 enables the reserved Fill adapter branch.
pub fn create_v5_fill_status<'info>(
    payer: &AccountInfo<'info>,
    fill_status: &AccountInfo<'info>,
    system_program_info: &AccountInfo<'info>,
    submitter: &Pubkey,
    relay_hash: &[u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    let (expected_payer, payer_bump) = Pubkey::find_program_address(&[V5_FILL_PAYER_SEED, submitter.as_ref()], &ID);
    let (expected_fill_status, fill_status_bump) = Pubkey::find_program_address(&[FILL_STATUS_SEED, relay_hash], &ID);
    require_keys_eq!(*payer.key, expected_payer, V5Error::InvalidFillPayer);
    require_keys_eq!(*fill_status.key, expected_fill_status, V5Error::InvalidFillStatusAccount);
    require_keys_eq!(*system_program_info.key, system_program::ID, V5Error::MissingAccount);
    require!(system_program_info.executable, V5Error::MissingAccount);
    require!(payer.is_writable && fill_status.is_writable, V5Error::InvalidAccountMutability);
    require_keys_eq!(*payer.owner, system_program::ID, V5Error::InvalidFillPayer);
    require!(payer.data_is_empty(), V5Error::InvalidFillPayer);
    require_keys_neq!(*fill_status.owner, ID, CommonError::RelayFilled);
    require_keys_eq!(*fill_status.owner, system_program::ID, V5Error::InvalidFillStatusAccount);
    require!(fill_status.data_is_empty(), V5Error::InvalidFillStatusAccount);

    let rent = Rent::get()?;
    let current_lamports = fill_status.lamports();
    let required_lamports = rent
        .minimum_balance(V5_FILL_STATUS_SPACE)
        .max(1)
        .saturating_sub(current_lamports);
    require_fill_payer_spend(payer.lamports(), required_lamports, rent.minimum_balance(0))?;

    let payer_seeds: &[&[u8]] = &[V5_FILL_PAYER_SEED, submitter.as_ref(), &[payer_bump]];
    let fill_status_seeds: &[&[u8]] = &[FILL_STATUS_SEED, relay_hash, &[fill_status_bump]];
    if current_lamports == 0 {
        invoke_signed(
            &system_instruction::create_account(
                payer.key,
                fill_status.key,
                required_lamports,
                V5_FILL_STATUS_SPACE as u64,
                &ID,
            ),
            &[payer.clone(), fill_status.clone(), system_program_info.clone()],
            &[payer_seeds, fill_status_seeds],
        )?;
    } else {
        if required_lamports > 0 {
            invoke_signed(
                &system_instruction::transfer(payer.key, fill_status.key, required_lamports),
                &[payer.clone(), fill_status.clone(), system_program_info.clone()],
                &[payer_seeds],
            )?;
        }
        invoke_signed(
            &system_instruction::allocate(fill_status.key, V5_FILL_STATUS_SPACE as u64),
            &[fill_status.clone(), system_program_info.clone()],
            &[fill_status_seeds],
        )?;
        invoke_signed(
            &system_instruction::assign(fill_status.key, &ID),
            &[fill_status.clone(), system_program_info.clone()],
            &[fill_status_seeds],
        )?;
    }

    write_v5_fill_status(fill_status, expected_payer, fill_deadline)
}

#[cfg(feature = "test")]
#[derive(Accounts)]
pub struct TestCreateV5FillStatus<'info> {
    /// CHECK: Validated by `create_v5_fill_status` against the submitter-scoped payer PDA.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,

    /// CHECK: Validated by `create_v5_fill_status` against the relay-scoped fill-status PDA.
    #[account(mut)]
    pub fill_status: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Test-only entrypoint for exercising the PDA-signed account-creation path before Step 4 wires it into V5 Fill.
#[cfg(feature = "test")]
pub fn test_create_v5_fill_status(
    ctx: Context<TestCreateV5FillStatus>,
    submitter: Pubkey,
    relay_hash: [u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    create_v5_fill_status(
        &ctx.accounts.payer.to_account_info(),
        &ctx.accounts.fill_status.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &submitter,
        &relay_hash,
        fill_deadline,
    )
}

#[allow(dead_code)] // Kept separate so the manual account creation has one serialization boundary.
fn write_v5_fill_status(fill_status: &AccountInfo, payer: Pubkey, fill_deadline: u32) -> Result<()> {
    let account = FillStatusAccount { status: FillStatus::Filled, relayer: payer, fill_deadline };
    account.try_serialize(&mut &mut fill_status.try_borrow_mut_data()?[..])
}

fn require_fill_payer_spend(balance: u64, amount: u64, rent_minimum: u64) -> Result<()> {
    let remaining = balance
        .checked_sub(amount)
        .ok_or_else(|| error!(V5Error::InsufficientFillPayerBalance))?;
    require!(remaining == 0 || remaining >= rent_minimum, V5Error::FillPayerRemainderNotRentExempt);
    Ok(())
}

#[derive(Accounts)]
pub struct WithdrawV5FillPayer<'info> {
    /// The float owner and the only withdrawal destination.
    #[account(mut)]
    pub submitter: Signer<'info>,

    /// CHECK: A data-less, system-owned float PDA derived from the signing submitter.
    #[account(
        mut,
        seeds = [V5_FILL_PAYER_SEED, submitter.key().as_ref()],
        bump,
        owner = system_program::ID
    )]
    pub payer: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Withdraws from the signing submitter's own fill-status rent float. `u64::MAX` drains the live balance.
pub fn withdraw_v5_fill_payer(ctx: Context<WithdrawV5FillPayer>, amount: u64) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    let balance = ctx.accounts.payer.lamports();
    let amount = if amount == u64::MAX { balance } else { amount };
    require_fill_payer_spend(balance, amount, Rent::get()?.minimum_balance(0))?;
    let seeds: &[&[u8]] = &[V5_FILL_PAYER_SEED, submitter.as_ref(), &[ctx.bumps.payer]];
    invoke_signed(
        &system_instruction::transfer(ctx.accounts.payer.key, &submitter, amount),
        &[
            ctx.accounts.payer.to_account_info(),
            ctx.accounts.submitter.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;
    emit!(V5FillFloatWithdrawn { submitter, amount });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use anchor_lang::Discriminator;

    fn assert_error_name(result: Result<()>, expected: &str) {
        match result.unwrap_err() {
            anchor_lang::error::Error::AnchorError(error) => assert_eq!(error.error_name, expected),
            _ => panic!("expected Anchor error"),
        }
    }

    #[test]
    fn payer_spend_requires_sufficient_balance_and_rent_safe_remainder() {
        assert!(require_fill_payer_spend(20, 10, 10).is_ok());
        assert!(require_fill_payer_spend(20, 20, 10).is_ok());
        assert_error_name(require_fill_payer_spend(20, 11, 10), "FillPayerRemainderNotRentExempt");
        assert_error_name(require_fill_payer_spend(20, 21, 10), "InsufficientFillPayerBalance");
    }

    #[test]
    fn v5_fill_status_keeps_legacy_layout_and_binds_the_payer_slot() {
        assert_eq!(V5_FILL_STATUS_SPACE, 8 + 1 + 32 + 4);
        assert_eq!(FillStatusAccount::DISCRIMINATOR.len(), DISCRIMINATOR_SIZE);

        let key = Pubkey::new_unique();
        let payer = Pubkey::new_unique();
        let owner = ID;
        let mut lamports = 1;
        let mut data = vec![0; V5_FILL_STATUS_SPACE];
        let account_info = AccountInfo::new(&key, false, true, &mut lamports, &mut data, &owner, false, 0);
        write_v5_fill_status(&account_info, payer, 123).unwrap();

        let fill_status =
            FillStatusAccount::try_deserialize(&mut &account_info.try_borrow_data().unwrap()[..]).unwrap();
        assert!(matches!(fill_status.status, FillStatus::Filled));
        assert_eq!(fill_status.relayer, payer);
        assert_eq!(fill_status.fill_deadline, 123);
    }
}
