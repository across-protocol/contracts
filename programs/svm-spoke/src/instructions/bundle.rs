use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::{
    associated_token,
    token_interface::{transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::DISCRIMINATOR_SIZE,
    error::{CommonError, SvmError},
    event::{ExecutedRelayerRefundRoot, TokensBridged},
    state::{ClaimAccount, ExecuteRelayerRefundLeafParams, RootBundle, State, TransferLiability},
    utils::{is_claimed, set_claimed, verify_merkle_proof},
};

#[event_cpi]
#[derive(Accounts)]
pub struct ExecuteRelayerRefundLeaf<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(mut, seeds = [b"instruction_params", signer.key().as_ref()], bump, close = signer)]
    pub instruction_params: Account<'info, ExecuteRelayerRefundLeafParams>, // Contains all leaf & proof information.

    #[account(seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        mut,
        seeds = [b"root_bundle", state.seed.to_le_bytes().as_ref(), instruction_params.root_bundle_id.to_le_bytes().as_ref()], bump,
        // Realloc to let the size of the dynamic array within root_bundle to grow as leafs are executed.
        realloc = std::cmp::max(
            DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE + instruction_params.relayer_refund_leaf.leaf_id as usize / 8,
            root_bundle.to_account_info().data_len()
        ),
        realloc::payer = signer,
        realloc::zero = false
    )]
    pub root_bundle: Account<'info, RootBundle>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state, // Ensure owner is the state.
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mint::token_program = token_program,
        address = instruction_params.relayer_refund_leaf.mint_public_key @ SvmError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        init_if_needed, // If first time creating, initialize the liability tracker, else re-use.
        payer = signer,
        space = DISCRIMINATOR_SIZE + TransferLiability::INIT_SPACE,
        seeds = [b"transfer_liability", mint.key().as_ref()],
        bump
    )]
    pub transfer_liability: Account<'info, TransferLiability>,

    pub token_program: Interface<'info, TokenInterface>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RelayerRefundLeaf {
    pub amount_to_return: u64,
    pub chain_id: u64,
    pub refund_amounts: Vec<u64>,
    pub leaf_id: u32,
    pub mint_public_key: Pubkey,
    pub refund_addresses: Vec<Pubkey>,
}

impl RelayerRefundLeaf {
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();

        // This requires the first 64 bytes to be 0 within the encoded leaf data. This protects any kind of EVM leaf
        // from ever being used on SVM (and vice versa). Note that the chain_id field in theory should protect this but
        // this 64 blank slot protects it under all cases (no leaves could ever collide due to encoding or type diffs).
        // 64 bytes covers the first two u256 elements of the struct on Solidity side, which forces the leaf & chain_id,
        // in interpreted by SVM, to be zero always blocking this leaf type on EVM.
        bytes.extend_from_slice(&[0u8; 64]);

        AnchorSerialize::serialize(&self, &mut bytes)?;

        Ok(bytes)
    }

    pub fn to_keccak_hash(&self) -> Result<[u8; 32]> {
        let input = self.to_bytes()?;

        Ok(keccak::hash(&input).to_bytes())
    }
}

pub fn execute_relayer_refund_leaf<'c, 'info>(
    ctx: Context<'_, '_, 'c, 'info, ExecuteRelayerRefundLeaf<'info>>,
    deferred_refunds: bool,
) -> Result<()>
where
    'c: 'info, // The lifetime constraint 'c: 'info ensures that the lifetime 'c is at least as long as 'info.
{
    // Get pre-loaded instruction parameters.
    let instruction_params = &ctx.accounts.instruction_params;
    let root_bundle_id = instruction_params.root_bundle_id;
    let relayer_refund_leaf = instruction_params.relayer_refund_leaf.to_owned();
    let proof = instruction_params.proof.to_owned();

    let state = &ctx.accounts.state;

    let root = ctx.accounts.root_bundle.relayer_refund_root;
    let leaf = relayer_refund_leaf.to_keccak_hash()?;
    verify_merkle_proof(root, leaf, proof)?;

    if relayer_refund_leaf.chain_id != state.chain_id {
        return err!(CommonError::InvalidChainId);
    }

    if is_claimed(&ctx.accounts.root_bundle.claimed_bitmap, relayer_refund_leaf.leaf_id) {
        return err!(CommonError::ClaimedMerkleLeaf);
    }

    set_claimed(&mut ctx.accounts.root_bundle.claimed_bitmap, relayer_refund_leaf.leaf_id);

    if relayer_refund_leaf.refund_addresses.len() != relayer_refund_leaf.refund_amounts.len() {
        return err!(CommonError::InvalidMerkleLeaf);
    }

    if ctx.remaining_accounts.len() < relayer_refund_leaf.refund_addresses.len() {
        return err!(ErrorCode::AccountNotEnoughKeys);
    }

    // Check if vault has sufficient balance for all the refunds.
    let total_refund_amount: u64 = relayer_refund_leaf.refund_amounts.iter().sum();
    if ctx.accounts.vault.amount < total_refund_amount {
        return err!(CommonError::InsufficientSpokePoolBalanceToExecuteLeaf);
    }

    // Depending on the called instruction flavor, we either accrue the refunds to claim accounts or transfer them.
    match deferred_refunds {
        true => accrue_relayer_refunds(&ctx, &relayer_refund_leaf)?,
        false => distribute_relayer_refunds(&ctx, &relayer_refund_leaf)?,
    }

    if relayer_refund_leaf.amount_to_return > 0 {
        ctx.accounts.transfer_liability.pending_to_hub_pool += relayer_refund_leaf.amount_to_return;

        emit_cpi!(TokensBridged {
            amount_to_return: relayer_refund_leaf.amount_to_return,
            chain_id: relayer_refund_leaf.chain_id,
            leaf_id: relayer_refund_leaf.leaf_id,
            l2_token_address: ctx.accounts.mint.key(),
            caller: ctx.accounts.signer.key(),
        });
    }

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
        let cpi_context =
            CpiContext::new_with_signer(ctx.accounts.token_program.to_account_info(), transfer_accounts, signer_seeds);
        transfer_checked(cpi_context, amount.to_owned(), ctx.accounts.mint.decimals)?;
    }

    Ok(())
}

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
