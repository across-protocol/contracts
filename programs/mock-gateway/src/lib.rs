use anchor_lang::{
    prelude::*,
    solana_program::{
        instruction::{AccountMeta, Instruction},
        program::invoke_signed,
    },
    InstructionData,
};
use anchor_spl::token_interface::{self, ApproveChecked, Mint, TokenAccount, TokenInterface};
use svm_spoke::program::SvmSpoke;

declare_id!("34trBszXuqhRjWaMxXWsunJNmyUsBvDNPxAwTzbPTm4p");

const DISPATCH_AUTHORITY_SEED: &[u8] = b"dispatch_authority";
const VAULT_AUTHORITY_SEED: &[u8] = b"vault_authority";

#[program]
pub mod mock_gateway {
    use super::*;

    pub fn execute_adapter(
        ctx: Context<ExecuteAdapter>,
        ctx_values: MockGatewayContext,
        input: Vec<u8>,
        jit_data: Vec<u8>,
        approval_amount: u64,
        fail_after: bool,
    ) -> Result<()> {
        let vault_seeds: &[&[u8]] = &[VAULT_AUTHORITY_SEED, &[ctx.bumps.vault_authority]];
        token_interface::approve_checked(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                ApproveChecked {
                    to: ctx.accounts.gateway_vault.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                    delegate: ctx.accounts.source_delegate.to_account_info(),
                    authority: ctx.accounts.vault_authority.to_account_info(),
                },
                &[vault_seeds],
            ),
            approval_amount,
            ctx.accounts.mint.decimals,
        )?;

        let svm_spoke_program = ctx.accounts.svm_spoke_program.key();
        let dispatch_seeds: &[&[u8]] = &[
            DISPATCH_AUTHORITY_SEED,
            svm_spoke_program.as_ref(),
            &[ctx.bumps.dispatch_authority],
        ];
        let accounts = vec![
            ctx.accounts.dispatch_authority.to_account_info(),
            ctx.accounts.state.to_account_info(),
            ctx.accounts.event_authority.to_account_info(),
            ctx.accounts.svm_spoke_program.to_account_info(),
            ctx.accounts.gateway_vault.to_account_info(),
            ctx.accounts.spoke_vault.to_account_info(),
            ctx.accounts.mint.to_account_info(),
            ctx.accounts.token_program.to_account_info(),
            ctx.accounts.source_delegate.to_account_info(),
        ];
        invoke_signed(
            &Instruction {
                program_id: svm_spoke::ID,
                accounts: vec![
                    AccountMeta::new_readonly(ctx.accounts.dispatch_authority.key(), true),
                    AccountMeta::new_readonly(ctx.accounts.state.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.event_authority.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.svm_spoke_program.key(), false),
                    AccountMeta::new(ctx.accounts.gateway_vault.key(), false),
                    AccountMeta::new(ctx.accounts.spoke_vault.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.mint.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.token_program.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.source_delegate.key(), false),
                ],
                data: svm_spoke::instruction::AdapterExecuteAcrossV5 {
                    ctx_values: svm_spoke::v5::V5GatewayContext {
                        step_id: ctx_values.step_id,
                        path_id: ctx_values.path_id,
                        submitter: ctx_values.submitter,
                    },
                    input,
                    jit_data,
                }
                .data(),
            },
            &accounts,
            &[dispatch_seeds],
        )?;
        require!(!fail_after, MockGatewayError::ForcedFailure);
        Ok(())
    }

    pub fn execute_fill_adapter(
        ctx: Context<ExecuteFillAdapter>,
        ctx_values: MockGatewayContext,
        input: Vec<u8>,
        jit_data: Vec<u8>,
        approval_amount: Option<u64>,
        consume_amount: u64,
        fail_after: bool,
    ) -> Result<()> {
        let vault_seeds: &[&[u8]] = &[VAULT_AUTHORITY_SEED, &[ctx.bumps.vault_authority]];
        if let Some(amount) = approval_amount {
            token_interface::approve_checked(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    ApproveChecked {
                        to: ctx.accounts.gateway_vault.to_account_info(),
                        mint: ctx.accounts.mint.to_account_info(),
                        delegate: ctx.accounts.fill_delegate.to_account_info(),
                        authority: ctx.accounts.vault_authority.to_account_info(),
                    },
                    &[vault_seeds],
                ),
                amount,
                ctx.accounts.mint.decimals,
            )?;
        }

        let svm_spoke_program = ctx.accounts.svm_spoke_program.key();
        let dispatch_seeds: &[&[u8]] = &[
            DISPATCH_AUTHORITY_SEED,
            svm_spoke_program.as_ref(),
            &[ctx.bumps.dispatch_authority],
        ];
        let accounts = vec![
            ctx.accounts.dispatch_authority.to_account_info(),
            ctx.accounts.state.to_account_info(),
            ctx.accounts.event_authority.to_account_info(),
            ctx.accounts.svm_spoke_program.to_account_info(),
            ctx.accounts.gateway_vault.to_account_info(),
            ctx.accounts.recipient_token_account.to_account_info(),
            ctx.accounts.mint.to_account_info(),
            ctx.accounts.token_program.to_account_info(),
            ctx.accounts.fill_delegate.to_account_info(),
            ctx.accounts.fill_payer.to_account_info(),
            ctx.accounts.fill_status.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ];
        invoke_signed(
            &Instruction {
                program_id: svm_spoke::ID,
                accounts: vec![
                    AccountMeta::new_readonly(ctx.accounts.dispatch_authority.key(), true),
                    AccountMeta::new_readonly(ctx.accounts.state.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.event_authority.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.svm_spoke_program.key(), false),
                    AccountMeta::new(ctx.accounts.gateway_vault.key(), false),
                    AccountMeta::new(ctx.accounts.recipient_token_account.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.mint.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.token_program.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.fill_delegate.key(), false),
                    AccountMeta::new(ctx.accounts.fill_payer.key(), false),
                    AccountMeta::new(ctx.accounts.fill_status.key(), false),
                    AccountMeta::new_readonly(ctx.accounts.system_program.key(), false),
                ],
                data: svm_spoke::instruction::AdapterExecuteAcrossV5 {
                    ctx_values: svm_spoke::v5::V5GatewayContext {
                        step_id: ctx_values.step_id,
                        path_id: ctx_values.path_id,
                        submitter: ctx_values.submitter,
                    },
                    input,
                    jit_data,
                }
                .data(),
            },
            &accounts,
            &[dispatch_seeds],
        )?;

        if consume_amount > 0 {
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    token_interface::TransferChecked {
                        from: ctx.accounts.gateway_vault.to_account_info(),
                        mint: ctx.accounts.mint.to_account_info(),
                        to: ctx.accounts.consumption_account.to_account_info(),
                        authority: ctx.accounts.vault_authority.to_account_info(),
                    },
                    &[vault_seeds],
                ),
                consume_amount,
                ctx.accounts.mint.decimals,
            )?;
        }
        require!(!fail_after, MockGatewayError::ForcedFailure);
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct MockGatewayContext {
    pub step_id: [u8; 32],
    pub path_id: [u8; 32],
    pub submitter: Pubkey,
}

#[derive(Accounts)]
pub struct ExecuteAdapter<'info> {
    pub submitter: Signer<'info>,

    /// CHECK: Test-only PDA that mirrors Gateway's canonical vault authority.
    #[account(seeds = [VAULT_AUTHORITY_SEED], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    /// CHECK: Test-only PDA that mirrors Gateway's per-callee dispatch authority.
    #[account(
        seeds = [DISPATCH_AUTHORITY_SEED, svm_spoke_program.key().as_ref()],
        bump
    )]
    pub dispatch_authority: UncheckedAccount<'info>,

    #[account(mut, token::mint = mint, token::authority = vault_authority, token::token_program = token_program)]
    pub gateway_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub spoke_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    /// CHECK: The svm-spoke adapter authenticates the static source-delegate key.
    pub source_delegate: UncheckedAccount<'info>,

    /// CHECK: Validated by the svm-spoke CPI account constraints.
    pub state: UncheckedAccount<'info>,

    /// CHECK: Validated by svm-spoke's event CPI machinery.
    pub event_authority: UncheckedAccount<'info>,

    pub token_program: Interface<'info, TokenInterface>,
    pub svm_spoke_program: Program<'info, SvmSpoke>,
}

#[derive(Accounts)]
pub struct ExecuteFillAdapter<'info> {
    pub submitter: Signer<'info>,

    /// CHECK: Test-only PDA that mirrors Gateway's canonical vault authority.
    #[account(seeds = [VAULT_AUTHORITY_SEED], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    /// CHECK: Test-only PDA that mirrors Gateway's per-callee dispatch authority.
    #[account(
        seeds = [DISPATCH_AUTHORITY_SEED, svm_spoke_program.key().as_ref()],
        bump
    )]
    pub dispatch_authority: UncheckedAccount<'info>,

    #[account(mut, token::mint = mint, token::authority = vault_authority, token::token_program = token_program)]
    pub gateway_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub consumption_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,

    /// CHECK: The svm-spoke adapter authenticates the static fill-delegate key for external delivery.
    pub fill_delegate: UncheckedAccount<'info>,

    /// CHECK: Validated by svm-spoke against the context submitter.
    #[account(mut)]
    pub fill_payer: UncheckedAccount<'info>,

    /// CHECK: Validated by svm-spoke against the relay hash.
    #[account(mut)]
    pub fill_status: UncheckedAccount<'info>,

    /// CHECK: Validated by the svm-spoke CPI account constraints.
    pub state: UncheckedAccount<'info>,

    /// CHECK: Validated by svm-spoke's event CPI machinery.
    pub event_authority: UncheckedAccount<'info>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
    pub svm_spoke_program: Program<'info, SvmSpoke>,
}

#[error_code]
pub enum MockGatewayError {
    #[msg("Forced failure after adapter execution")]
    ForcedFailure,
}
