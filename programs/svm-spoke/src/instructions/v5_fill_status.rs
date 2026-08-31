use anchor_lang::{
    prelude::*,
    solana_program::{program::invoke_signed, system_instruction, system_program},
};

use crate::{
    constants::{DISCRIMINATOR_SIZE, FILL_STATUS_SEED, V5_FILL_PAYER_SEED},
    error::{CommonError, V5Error},
    event::V5FillFloatWithdrawn,
    state::{FillStatus, FillStatusAccount},
    v5::{derive_fill_status, derive_v5_fill_payer},
    ID,
};

pub const V5_FILL_STATUS_SPACE: usize = DISCRIMINATOR_SIZE + FillStatusAccount::INIT_SPACE;

/// Creates or updates a V5 fill status using program-derived signers only. For an uninitialized account, the creation
/// sequence intentionally mirrors Anchor 0.31.1's generated `init_if_needed` implementation in
/// `anchor-syn/src/codegen/accounts/constraints.rs::generate_create_account`: create an unfunded account, or top up,
/// allocate, and assign a prefunded account. This must be expanded here because Gateway does not forward the transaction
/// signer and Anchor cannot use the submitter-scoped payer PDA as its payer; `invoke_signed` supplies that signature only
/// to the nested System Program calls. An existing filled account is rejected as a replay; other program-owned states
/// are invalid because V5-tagged relays cannot enter the slow-fill lifecycle. Storing the payer PDA in the existing
/// `relayer` slot binds permissionless expiry reclaim to the correct float without changing the account layout; legacy
/// fills continue to store their signing relayer there.
///
/// # Safety
///
/// The caller must source `submitter` from Gateway-attested context, derive `relay_hash` from the same validated V5
/// `RelayData` that supplies `fill_deadline`, and reject an expired `fill_deadline` before calling this helper. This
/// helper validates accounts derived from those values but does not authenticate or bind the values themselves.
#[allow(dead_code)] // Called when Step 4 enables the reserved Fill adapter branch.
pub fn create_v5_fill_status<'info>(
    payer: &AccountInfo<'info>,
    fill_status: &AccountInfo<'info>,
    system_program_info: &AccountInfo<'info>,
    submitter: &Pubkey,
    relay_hash: &[u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    let (expected_payer, payer_bump) = derive_v5_fill_payer(submitter);
    let (expected_fill_status, fill_status_bump) = derive_fill_status(relay_hash);
    require_keys_eq!(*payer.key, expected_payer, V5Error::InvalidFillPayer);
    require_keys_eq!(*fill_status.key, expected_fill_status, V5Error::InvalidFillStatusAccount);
    require_keys_eq!(*system_program_info.key, system_program::ID, V5Error::MissingAccount);
    require!(system_program_info.executable, V5Error::MissingAccount);
    require!(payer.is_writable && fill_status.is_writable, V5Error::InvalidAccountMutability);
    require_keys_eq!(*payer.owner, system_program::ID, V5Error::InvalidFillPayer);
    require!(payer.data_is_empty(), V5Error::InvalidFillPayer);
    if fill_status.owner == &ID {
        let data = fill_status.try_borrow_data()?;
        let existing = FillStatusAccount::try_deserialize(&mut &data[..])
            .map_err(|_| error!(V5Error::InvalidFillStatusAccount))?;
        match existing.status {
            FillStatus::Filled => return err!(CommonError::RelayFilled),
            FillStatus::Unfilled | FillStatus::RequestedSlowFill => return err!(V5Error::InvalidFillStatusAccount),
        }
    }
    let current_lamports = fill_status.lamports();
    let required_lamports = Rent::get()?
        .minimum_balance(V5_FILL_STATUS_SPACE)
        .max(1)
        .saturating_sub(current_lamports);
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

    FillStatusAccount { status: FillStatus::Filled, relayer: expected_payer, fill_deadline }
        .try_serialize(&mut &mut fill_status.try_borrow_mut_data()?[..])
}

#[cfg(feature = "test")]
#[derive(Accounts)]
pub struct TestCreateV5FillStatus<'info> {
    pub submitter: Signer<'info>,

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
    relay_hash: [u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    create_v5_fill_status(
        &ctx.accounts.payer.to_account_info(),
        &ctx.accounts.fill_status.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &submitter,
        &relay_hash,
        fill_deadline,
    )?;
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
        bump
    )]
    pub payer: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Withdraws from the signing submitter's own fill-status rent float. `u64::MAX` drains the live balance.
pub fn withdraw_v5_fill_payer(ctx: Context<WithdrawV5FillPayer>, amount: u64) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    let balance = ctx.accounts.payer.lamports();
    let amount = if amount == u64::MAX { balance } else { amount };
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
