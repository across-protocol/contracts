use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::{
    associated_token,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::DISCRIMINATOR_SIZE,
    error::{CommonError, SvmError},
    event::ExecutedRelayerRefundRoot,
    state::{ClaimAccount, ExecuteRelayerRefundLeafParams, RootBundle, State, TransferLiability},
    utils::{is_claimed, set_claimed, verify_merkle_proof},
};

#[event_cpi]
#[derive(Accounts)]
pub struct ExecuteRelayerRefundLeaf<'info> {
    /// Signer initiating the relayer refund execution.
    #[account(mut)]
    pub signer: Signer<'info>,

    /// Instruction parameters containing the leaf and proof information.
    #[account(seeds = [b"instruction_params", signer.key().as_ref()], bump)]
    pub instruction_params: Account<'info, ExecuteRelayerRefundLeafParams>,

    /// State account storing global configurations and the relayer refund root.
    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    /// Root bundle PDA containing the relayer refund root and a claimed bitmap.
    #[account(
        mut,
        seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), instruction_params.root_bundle_id.to_le_bytes().as_ref()],
        bump,
        // Reallocates the account size to track executed leaves in the claimed bitmap.
        realloc = std::cmp::max(
            DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE + instruction_params.relayer_refund_leaf.leaf_id as usize / 8,
            root_bundle.to_account_info().data_len()
        ),
        realloc::payer = signer,
        realloc::zero = false
    )]
    pub root_bundle: Account<'info, RootBundle>,

    /// Vault ATA holding tokens to be refunded.
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    /// Mint account for the refunded tokens.
    #[account(
        mint::token_program = token_program,
        address = instruction_params.relayer_refund_leaf.mint_public_key @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    /// Liability tracker for deferred refunds to the hub pool.
    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + TransferLiability::INIT_SPACE,
        seeds = [b"transfer_liability", mint.key().as_ref()],
        bump
    )]
    pub transfer_liability: Account<'info, TransferLiability>,

    /// Token program for CPI interactions.
    pub token_program: Interface<'info, TokenInterface>,

    /// System program for reallocations and account initialization.
    pub system_program: Program<'info, System>,
}

/// Represents a relayer refund leaf with details for token refunds.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct RelayerRefundLeaf {
    pub amount_to_return: u64, // Amount to return to the hub pool.
    pub chain_id: u64,         // Chain ID for the refund.
    #[max_len(0)]
    pub refund_amounts: Vec<u64>, // Amounts to refund to individual accounts.
    pub leaf_id: u32,          // Unique ID of the Merkle leaf.
    pub mint_public_key: Pubkey, // Token mint public key for the refund.
    #[max_len(0)]
    pub refund_addresses: Vec<Pubkey>, // Addresses to receive the refunds.
}

impl RelayerRefundLeaf {
    /// Serializes the leaf to a byte array, ensuring compatibility with SVM and EVM environments.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&[0u8; 64]); // Adds 64 bytes of zero padding for cross-environment safety.
        AnchorSerialize::serialize(self, &mut bytes)?;
        Ok(bytes)
    }

    /// Generates a Keccak hash of the serialized leaf.
    pub fn to_keccak_hash(&self) -> Result<[u8; 32]> {
        let input = self.to_bytes()?;
        Ok(keccak::hash(&input).to_bytes())
    }
}

/// Executes a relayer refund leaf, either deferring refunds or distributing them immediately.
/// ### Parameters:
/// - `deferred_refunds`: Whether to defer the refunds or distribute them immediately.
pub fn execute_relayer_refund_leaf<'c, 'info>(
    ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    deferred_refunds: bool,
) -> Result<()>
where
    'c: 'info,
{
    let instruction_params = &ctx.accounts.instruction_params;
    let root_bundle_id = instruction_params.root_bundle_id;
    let relayer_refund_leaf = instruction_params.relayer_refund_leaf.to_owned();
    let proof = instruction_params.proof.to_owned();

    let state = &ctx.accounts.state;

    // Verify the Merkle proof for the refund leaf.
    let root = ctx.accounts.root_bundle.relayer_refund_root;
    let leaf = relayer_refund_leaf.to_keccak_hash()?;
    verify_merkle_proof(root, leaf, proof)?;

    if relayer_refund_leaf.chain_id != state.chain_id {
        return err!(CommonError::InvalidChainId);
    }

    // Check if the leaf has already been claimed.
    if is_claimed(&ctx.accounts.root_bundle.claimed_bitmap, relayer_refund_leaf.leaf_id) {
        return err!(CommonError::ClaimedMerkleLeaf);
    }

    // Mark the leaf as claimed in the root bundle's bitmap.
    set_claimed(
        &mut ctx.accounts.root_bundle.claimed_bitmap,
        relayer_refund_leaf.leaf_id,
    );

    // Ensure refund addresses and amounts match in length.
    if relayer_refund_leaf.refund_addresses.len() != relayer_refund_leaf.refund_amounts.len() {
        return err!(CommonError::InvalidMerkleLeaf);
    }

    // Validate sufficient refund accounts.
    if ctx.remaining_accounts.len() < relayer_refund_leaf.refund_addresses.len() {
        return err!(ErrorCode::AccountNotEnoughKeys);
    }

    // Check if the vault has enough balance to cover all refunds.
    let total_refund_amount: u64 = relayer_refund_leaf.refund_amounts.iter().sum();
    if ctx.accounts.vault.amount < total_refund_amount {
        return err!(CommonError::InsufficientSpokePoolBalanceToExecuteLeaf);
    }

    // Handle refunds either by accruing or distributing.
    match deferred_refunds {
        true => accrue_relayer_refunds(&ctx, &relayer_refund_leaf)?,
        false => distribute_relayer_refunds(&ctx, &relayer_refund_leaf)?,
    }

    // Update the pending liability to the hub pool if applicable.
    if relayer_refund_leaf.amount_to_return > 0 {
        ctx.accounts.transfer_liability.pending_to_hub_pool += relayer_refund_leaf.amount_to_return;
    }

    // Emit an event for the executed relayer refund.
    emit_cpi!(ExecutedRelayerRefundRoot {
        amount_to_return: relayer_refund_leaf.amount_to_return,
        chain_id: relayer_refund_leaf.chain_id,
        refund_amounts: relayer_refund_leaf.refund_amounts,
        root_bundle_id,
        leaf_id: relayer_refund_leaf.leaf_id,
        l2_token_address: ctx.accounts.mint.key(),
        refund_addresses: relayer_refund_leaf.refund_addresses,
        deferred_refunds,
        caller: ctx.accounts.signer.key(),
    });

    Ok(())
}

/// Distributes relayer refunds directly to recipient accounts.
/// ### Parameters:
/// - `relayer_refund_leaf`: The leaf containing the refund details.
fn distribute_relayer_refunds<'info>(
    ctx: &Context<'_, '_, '_, 'info, ExecuteRelayerRefundLeaf<'info>>,
    relayer_refund_leaf: &RelayerRefundLeaf,
) -> Result<()> {
    // Derive the signer seeds for the state. The vault owns the state PDA so we need to derive this to create the
    // signer seeds to execute the CPI transfer from the vault to the refund recipient's token account.
    let state_seed_bytes = ctx.accounts.state.seed.to_le_bytes();
    let seeds = &[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]];
    let signer_seeds = &[&seeds[..]];

    for (i, amount) in relayer_refund_leaf.refund_amounts.iter().enumerate() {
        // We only need to check the refund account matches the associated token address for the relayer.
        // All other required checks are performed within the transfer CPI. We do not check the token account authority
        // as the relayer might have transferred it to a multisig or any other wallet.
        // It should be safe to access elements of refund_addresses and remaining_accounts as their lengths are checked
        // before calling this internal function.
        let refund_token_account = &ctx.remaining_accounts[i];
        let associated_token_address = associated_token::get_associated_token_address_with_program_id(
            &relayer_refund_leaf.refund_addresses[i],
            &ctx.accounts.mint.key(),
            &ctx.accounts.token_program.key(),
        );

        if refund_token_account.key() != associated_token_address {
            return Err(Error::from(SvmError::InvalidRefund).with_account_name(&format!("remaining_accounts[{}]", i)));
        }

        let transfer_accounts = TransferChecked {
            from: ctx.accounts.vault.to_account_info(),
            mint: ctx.accounts.mint.to_account_info(),
            to: refund_token_account.to_account_info(),
            authority: ctx.accounts.state.to_account_info(),
        };
        let cpi_context = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            transfer_accounts,
            signer_seeds,
        );
        transfer_checked(cpi_context, amount.to_owned(), ctx.accounts.mint.decimals)?;
    }

    Ok(())
}

/// Accrues refunds to claim accounts instead of transferring directly.
/// ### Parameters:
/// - `relayer_refund_leaf`: The leaf containing the refund details.
fn accrue_relayer_refunds<'c, 'info>(
    ctx: &Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    relayer_refund_leaf: &RelayerRefundLeaf,
) -> Result<()>
where
    'c: 'info,
{
    for (i, amount) in relayer_refund_leaf.refund_amounts.iter().enumerate() {
        // It should be safe to access elements of refund_addresses and remaining_accounts as their lengths are checked
        // before calling this internal function.
        let mut claim_account = ClaimAccount::try_from(
            &ctx.remaining_accounts[i],
            &relayer_refund_leaf.mint_public_key,
            &relayer_refund_leaf.refund_addresses[i],
        )
        .map_err(|e| e.with_account_name(&format!("remaining_accounts[{}]", i)))?;

        claim_account.amount += amount;

        // Persist the updated claim account (Anchor handles this only for static accounts).
        claim_account
            .exit(ctx.program_id)
            .map_err(|e| e.with_account_name(&format!("remaining_accounts[{}]", i)))?;
    }

    Ok(())
}
