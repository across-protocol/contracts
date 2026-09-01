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

pub struct V5FillStatusPdas<'a> {
    submitter: &'a Pubkey,
    relay_hash: &'a [u8; 32],
    payer: Pubkey,
    fill_status: Pubkey,
    payer_bump: u8,
    fill_status_bump: u8,
}

impl<'a> V5FillStatusPdas<'a> {
    #[cfg_attr(not(feature = "test"), allow(dead_code))]
    pub fn derive(submitter: &'a Pubkey, relay_hash: &'a [u8; 32]) -> Self {
        let (payer, payer_bump) = derive_v5_fill_payer(submitter);
        let (fill_status, fill_status_bump) = derive_fill_status(relay_hash);
        Self { submitter, relay_hash, payer, fill_status, payer_bump, fill_status_bump }
    }

    pub fn payer(&self) -> Pubkey {
        self.payer
    }

    pub fn fill_status(&self) -> Pubkey {
        self.fill_status
    }
}

#[must_use = "V5 fill-status storage must be finalized with write_filled"]
pub struct PendingV5FillStatus<'a, 'info> {
    fill_status: AccountInfo<'info>,
    pdas: &'a V5FillStatusPdas<'a>,
}

impl PendingV5FillStatus<'_, '_> {
    /// Serializes the terminal V5 fill status after the caller completes semantic validation and token delivery.
    #[cfg_attr(not(feature = "test"), allow(dead_code))]
    pub fn write_filled(self, fill_deadline: u32) -> Result<()> {
        FillStatusAccount { status: FillStatus::Filled, relayer: self.pdas.payer(), fill_deadline }
            .try_serialize(&mut &mut self.fill_status.try_borrow_mut_data()?[..])
    }
}

/// Creates or assigns the zeroed storage for a V5 fill-status PDA using program-derived signers only. The creation
/// sequence intentionally mirrors Anchor 0.31.1's generated `init_if_needed` implementation in
/// `anchor-syn/src/codegen/accounts/constraints.rs::generate_create_account`: create an unfunded account, or top up,
/// allocate, and assign a prefunded account. This must be expanded here because Gateway does not forward the transaction
/// signer and Anchor cannot use the submitter-scoped payer PDA as its payer; `invoke_signed` supplies that signature only
/// to the nested System Program calls. An existing filled account is rejected as a replay; other program-owned states
/// are invalid because V5-tagged relays cannot enter the slow-fill lifecycle.
///
/// # Safety
///
/// The caller must derive `pdas` from the Gateway-attested submitter and the relay hash of the validated V5 `RelayData`,
/// then complete semantic validation before calling this helper. Every successful instruction path must then call
/// `PendingV5FillStatus::write_filled` with the unexpired deadline committed in that `RelayData`; failed paths atomically
/// roll back the zeroed intermediate account.
pub fn create_v5_fill_status_account<'a, 'info>(
    payer: &AccountInfo<'info>,
    fill_status: &AccountInfo<'info>,
    system_program_info: &AccountInfo<'info>,
    pdas: &'a V5FillStatusPdas<'a>,
) -> Result<PendingV5FillStatus<'a, 'info>> {
    require_keys_eq!(*payer.key, pdas.payer(), V5Error::InvalidFillPayer);
    require_keys_eq!(*fill_status.key, pdas.fill_status(), V5Error::InvalidFillStatusAccount);
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
    let payer_seeds: &[&[u8]] = &[V5_FILL_PAYER_SEED, pdas.submitter.as_ref(), &[pdas.payer_bump]];
    let fill_status_seeds: &[&[u8]] = &[FILL_STATUS_SEED, pdas.relay_hash, &[pdas.fill_status_bump]];
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

    Ok(PendingV5FillStatus { fill_status: fill_status.clone(), pdas })
}

#[cfg(feature = "test")]
#[derive(Accounts)]
pub struct TestCreateV5FillStatus<'info> {
    pub submitter: Signer<'info>,

    /// CHECK: Validated by `create_v5_fill_status_account` against the submitter-scoped payer PDA.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,

    /// CHECK: Validated by `create_v5_fill_status_account` against the relay-scoped fill-status PDA.
    #[account(mut)]
    pub fill_status: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

/// Test-only entrypoint for focused coverage of the PDA-signed account-creation lifecycle.
#[cfg(feature = "test")]
pub fn test_create_v5_fill_status(
    ctx: Context<TestCreateV5FillStatus>,
    relay_hash: [u8; 32],
    fill_deadline: u32,
) -> Result<()> {
    let submitter = ctx.accounts.submitter.key();
    let pdas = V5FillStatusPdas::derive(&submitter, &relay_hash);
    let pending_fill_status = create_v5_fill_status_account(
        &ctx.accounts.payer.to_account_info(),
        &ctx.accounts.fill_status.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        &pdas,
    )?;
    pending_fill_status.write_filled(fill_deadline)
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
