use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak;

use crate::{
    constants::DISCRIMINATOR_SIZE,
    error::CustomError,
    event::ExecutedRelayerRefundRoot,
    state::{ExecuteRelayerRefundLeafParams, RootBundle, State, TransferLiability},
    utils::{is_claimed, set_claimed, verify_merkle_proof},
};

use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

#[event_cpi]
#[derive(Accounts)]
pub struct ExecuteRelayerRefundLeaf<'info> {
    #[account(
        seeds = [b"instruction_params", signer.key().as_ref()],
        bump
    )]
    pub instruction_params: Account<'info, ExecuteRelayerRefundLeafParams>,

    #[account(mut, seeds = [b"state", state.seed.to_le_bytes().as_ref()], bump)]
    pub state: Account<'info, State>,

    #[account(
        mut,
        seeds =[b"root_bundle", state.key().as_ref(), instruction_params.root_bundle_id.to_le_bytes().as_ref()], bump,
        realloc = std::cmp::max(
            DISCRIMINATOR_SIZE + RootBundle::INIT_SPACE + instruction_params.relayer_refund_leaf.leaf_id as usize / 8,
            root_bundle.to_account_info().data_len()
        ),
        realloc::payer = signer,
        realloc::zero = false
    )]
    pub root_bundle: Account<'info, RootBundle>,

    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = state,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        mint::token_program = token_program,
        address = instruction_params.relayer_refund_leaf.mint_public_key @ CustomError::InvalidMint
    )]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        init_if_needed,
        payer = signer,
        space = DISCRIMINATOR_SIZE + TransferLiability::INIT_SPACE,
        seeds = [b"transfer_liability", mint.key().as_ref()],
        bump
    )]
    pub transfer_liability: Account<'info, TransferLiability>,

    pub token_program: Interface<'info, TokenInterface>,

    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct RelayerRefundLeaf {
    pub amount_to_return: u64,
    pub chain_id: u64,
    pub leaf_id: u32,
    pub mint_public_key: Pubkey,
    #[max_len(0)]
    pub refund_amounts: Vec<u64>,
    #[max_len(0)]
    pub refund_accounts: Vec<Pubkey>,
}

impl RelayerRefundLeaf {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();

        bytes.extend_from_slice(&self.amount_to_return.to_le_bytes());
        bytes.extend_from_slice(&self.chain_id.to_le_bytes());
        bytes.extend_from_slice(&self.leaf_id.to_le_bytes());
        bytes.extend_from_slice(self.mint_public_key.as_ref());

        for amount in &self.refund_amounts {
            bytes.extend_from_slice(&amount.to_le_bytes());
        }
        for account in &self.refund_accounts {
            bytes.extend_from_slice(account.as_ref());
        }

        bytes
    }

    pub fn to_keccak_hash(&self) -> [u8; 32] {
        let input = self.to_bytes();
        keccak::hash(&input).0
    }
}

pub fn execute_relayer_refund_leaf<'info>(
    ctx: Context<'_, '_, '_, 'info, ExecuteRelayerRefundLeaf<'info>>,
) -> Result<()> {
    // Get pre-loaded instruction parameters.
    let instruction_params = &ctx.accounts.instruction_params;
    let root_bundle_id = instruction_params.root_bundle_id;
    let relayer_refund_leaf = instruction_params.relayer_refund_leaf.to_owned();
    let proof = instruction_params.proof.to_owned();

    let state = &mut ctx.accounts.state;

    let root = ctx.accounts.root_bundle.relayer_refund_root;
    let leaf = relayer_refund_leaf.to_keccak_hash();
    verify_merkle_proof(root, leaf, proof)?;

    if relayer_refund_leaf.chain_id != state.chain_id {
        return Err(CustomError::InvalidChainId.into());
    }

    if is_claimed(
        &ctx.accounts.root_bundle.claimed_bitmap,
        relayer_refund_leaf.leaf_id,
    ) {
        return Err(CustomError::LeafAlreadyClaimed.into());
    }

    set_claimed(
        &mut ctx.accounts.root_bundle.claimed_bitmap,
        relayer_refund_leaf.leaf_id,
    );

    // TODO: execute remaining parts of leaf structure such as amountToReturn.
    // TODO: emit events.

    // Derive the signer seeds for the state. The vault owns the state PDA so we need to derive this to create the
    // signer seeds to execute the CPI transfer from the vault to the refund recipient.
    let state_seed_bytes = state.seed.to_le_bytes();
    let seeds = &[b"state", state_seed_bytes.as_ref(), &[ctx.bumps.state]];
    let signer_seeds = &[&seeds[..]];

    for (i, amount) in relayer_refund_leaf.refund_amounts.iter().enumerate() {
        let refund_account = relayer_refund_leaf.refund_accounts[i];
        let amount = *amount as u64;

        // TODO: we might be able to just use the refund_account and improve this block but it's not clear yet if that's possible.
        let refund_account_info = ctx
            .remaining_accounts
            .iter()
            .find(|account| account.key == &refund_account)
            .cloned()
            .ok_or(CustomError::AccountNotFound)?;

        let transfer_accounts = TransferChecked {
            from: ctx.accounts.vault.to_account_info(),
            mint: ctx.accounts.mint.to_account_info(),
            to: refund_account_info.to_account_info(),
            authority: ctx.accounts.state.to_account_info(),
        };
        let cpi_context = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            transfer_accounts,
            signer_seeds,
        );
        transfer_checked(cpi_context, amount, ctx.accounts.mint.decimals)?;
    }

    if relayer_refund_leaf.amount_to_return > 0 {
        ctx.accounts.transfer_liability.pending_to_hub_pool += relayer_refund_leaf.amount_to_return;
    }

    // Emit the ExecutedRelayerRefundRoot event
    emit_cpi!(ExecutedRelayerRefundRoot {
        amount_to_return: relayer_refund_leaf.amount_to_return,
        chain_id: relayer_refund_leaf.chain_id,
        refund_amounts: relayer_refund_leaf.refund_amounts,
        root_bundle_id,
        leaf_id: relayer_refund_leaf.leaf_id,
        l2_token_address: ctx.accounts.mint.key(),
        refund_addresses: relayer_refund_leaf.refund_accounts,
        caller: ctx.accounts.signer.key(),
    });

    Ok(())
}
