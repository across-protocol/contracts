use anchor_lang::{prelude::*, solana_program::keccak};
use anchor_spl::{associated_token::get_associated_token_address_with_program_id, token_interface::TransferChecked};

use crate::{
    constants::{GATEWAY_VAULT_AUTHORITY, V5_FILL_DELEGATE, V5_FILL_DELEGATE_SEED, V5_MAGIC_PREFIX},
    error::{CommonError, V5Error},
    event::{FillType, FilledRelay, RelayExecutionEventInfo},
    utils::{get_current_time, get_relay_hash, transfer_from},
    v5::{
        accounts::find_v5_account,
        codec::{decode_strict, GatewayContextV1, V5FillInput, V5FillJit},
        fill_status::{create_v5_fill_status_account, V5FillStatusPdas},
    },
};

use super::{
    token::{load_token_account, V5TokenAccounts},
    AdapterExecuteAcrossV5,
};

pub(super) fn execute_v5_fill<'info>(
    ctx: Context<'_, '_, '_, 'info, AdapterExecuteAcrossV5<'info>>,
    ctx_values: GatewayContextV1,
    fill_input: V5FillInput,
    jit_data: &[u8],
) -> Result<()> {
    // Fail fast before decoding fill JIT data.
    require!(!ctx.accounts.state.paused_fills, CommonError::FillsArePaused);

    let jit: V5FillJit = decode_strict(jit_data)?;
    let relay = &jit.relay_data;
    require!(
        relay.recipient == fill_input.recipient
            && relay.output_token == fill_input.output_token
            && relay.message.len() == 64
            && relay.message[..32] == V5_MAGIC_PREFIX
            && relay.message[32..] == ctx_values.step_id,
        V5Error::FillCommitmentMismatch
    );
    require!(relay.output_amount >= fill_input.min_output_amount, V5Error::FillOutputAmountTooLow);

    let message_hash = keccak::hash(&relay.message).to_bytes();
    let relay_hash = get_relay_hash(relay, ctx.accounts.state.chain_id, &message_hash);
    let accounts = V5FillAccounts::load(ctx.remaining_accounts, &fill_input, &ctx_values.submitter, &relay_hash)?;
    let current_time = get_current_time(&ctx.accounts.state)?;

    // Check if the exclusivity deadline has passed or if the caller is the exclusive relayer.
    if relay.exclusive_relayer != ctx_values.submitter
        && relay.exclusivity_deadline >= current_time
        && relay.exclusive_relayer != Pubkey::default()
    {
        return err!(CommonError::NotExclusiveRelayer);
    }

    // Check if the fill deadline has passed.
    if relay.fill_deadline < current_time {
        return err!(CommonError::ExpiredFillDeadline);
    }

    // Account creation rejects existing program-owned state; V5 has no slow-fill lifecycle.
    let fill_status = create_v5_fill_status_account(
        &accounts.payer,
        &accounts.fill_status,
        &accounts.system_program,
        &accounts.fill_status_pdas,
    )?;

    // Self-transfers validate balance, frozen state, and authority without debiting funds or allowance.
    // The committed Gateway tape must enforce balance checks covering all fill obligations and consume the funds.
    transfer_from(
        accounts.transfer,
        accounts.token_program,
        relay.output_amount,
        accounts.mint_decimals,
        V5_FILL_DELEGATE_SEED,
    )?;

    // Update the fill status and rent-reclaim metadata; V5 stores its payer PDA as the rent recipient.
    fill_status.write_filled(relay.fill_deadline)?;

    emit_cpi!(FilledRelay {
        input_token: relay.input_token,
        output_token: relay.output_token,
        input_amount: relay.input_amount,
        output_amount: relay.output_amount,
        repayment_chain_id: jit.repayment_chain_id,
        origin_chain_id: relay.origin_chain_id,
        deposit_id: relay.deposit_id,
        fill_deadline: relay.fill_deadline,
        exclusivity_deadline: relay.exclusivity_deadline,
        exclusive_relayer: relay.exclusive_relayer,
        relayer: jit.repayment_address,
        depositor: relay.depositor,
        recipient: relay.recipient,
        message_hash,
        relay_execution_info: RelayExecutionEventInfo {
            updated_recipient: relay.recipient,
            updated_message_hash: [0; 32],
            updated_output_amount: relay.output_amount,
            fill_type: FillType::FastFill,
        },
    });
    Ok(())
}

struct V5FillAccounts<'a, 'info> {
    transfer: TransferChecked<'info>,
    token_program: AccountInfo<'info>,
    mint_decimals: u8,
    payer: AccountInfo<'info>,
    fill_status: AccountInfo<'info>,
    system_program: AccountInfo<'info>,
    fill_status_pdas: V5FillStatusPdas<'a>,
}

impl<'a, 'info> V5FillAccounts<'a, 'info> {
    fn load(
        remaining_accounts: &[AccountInfo<'info>],
        fill_input: &V5FillInput,
        submitter: &'a Pubkey,
        relay_hash: &'a [u8; 32],
    ) -> Result<Self> {
        let token_accounts = V5TokenAccounts::load(remaining_accounts, &fill_input.output_token)?;
        let recipient_info = if fill_input.recipient == GATEWAY_VAULT_AUTHORITY {
            // The shared loader validated this writable vault, including its token authority. No CPI has intervened.
            token_accounts.gateway_vault.clone()
        } else {
            let recipient = get_associated_token_address_with_program_id(
                &fill_input.recipient,
                &fill_input.output_token,
                token_accounts.token_program.key,
            );
            let recipient_info = find_v5_account(remaining_accounts, &recipient, true)?;
            load_token_account(
                recipient_info,
                token_accounts.token_program.key,
                &fill_input.output_token,
                &fill_input.recipient,
            )?;
            recipient_info.clone()
        };

        let delegate = find_v5_account(remaining_accounts, &V5_FILL_DELEGATE, false)?;

        let fill_status_pdas = V5FillStatusPdas::derive(submitter, relay_hash);
        let payer_info = find_v5_account(remaining_accounts, &fill_status_pdas.payer(), true)?;
        let fill_status_info = find_v5_account(remaining_accounts, &fill_status_pdas.fill_status(), true)?;
        let system_program_info = find_v5_account(remaining_accounts, &anchor_lang::system_program::ID, false)?;

        Ok(Self {
            transfer: TransferChecked {
                from: token_accounts.gateway_vault,
                mint: token_accounts.mint,
                to: recipient_info,
                authority: delegate.clone(),
            },
            token_program: token_accounts.token_program,
            mint_decimals: token_accounts.mint_decimals,
            payer: payer_info.clone(),
            fill_status: fill_status_info.clone(),
            system_program: system_program_info.clone(),
            fill_status_pdas,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anchor_lang::solana_program::{program_option::COption, program_pack::Pack};
    use anchor_spl::token::spl_token::state::{Account, AccountState, Mint};

    const AMOUNT: u64 = 500_000;
    const SUBMITTER: Pubkey = Pubkey::new_from_array([0; 32]);

    fn account(key: Pubkey, owner: Pubkey, data: Vec<u8>, writable: bool) -> AccountInfo<'static> {
        AccountInfo::new(
            Box::leak(Box::new(key)),
            false,
            writable,
            Box::leak(Box::new(1)),
            Box::leak(data.into_boxed_slice()),
            Box::leak(Box::new(owner)),
            false,
            0,
        )
    }

    fn fixture(token_program: Pubkey, in_place: bool) -> (V5FillInput, Vec<AccountInfo<'static>>) {
        let mint = Pubkey::new_unique();
        let recipient = if in_place {
            GATEWAY_VAULT_AUTHORITY
        } else {
            Pubkey::new_unique()
        };
        let vault = get_associated_token_address_with_program_id(&GATEWAY_VAULT_AUTHORITY, &mint, &token_program);
        let mut mint_data = vec![0; Mint::LEN];
        Mint::pack(Mint { decimals: 6, is_initialized: true, ..Mint::default() }, &mut mint_data).unwrap();
        let mut vault_data = vec![0; Account::LEN];
        Account::pack(
            Account {
                mint,
                owner: GATEWAY_VAULT_AUTHORITY,
                amount: AMOUNT,
                state: AccountState::Initialized,
                delegate: COption::Some(V5_FILL_DELEGATE),
                delegated_amount: AMOUNT,
                ..Account::default()
            },
            &mut vault_data,
        )
        .unwrap();
        let pdas = V5FillStatusPdas::derive(&SUBMITTER, &[0; 32]);
        let system = anchor_lang::system_program::ID;
        let mut accounts = vec![
            account(vault, token_program, vault_data, true),
            account(mint, token_program, mint_data, false),
            account(token_program, system, vec![], false),
            account(pdas.payer(), system, vec![], true),
            account(pdas.fill_status(), system, vec![], true),
            account(system, system, vec![], false),
            account(V5_FILL_DELEGATE, system, vec![], false),
        ];
        if !in_place {
            let ata = get_associated_token_address_with_program_id(&recipient, &mint, &token_program);
            let mut data = vec![0; Account::LEN];
            Account::pack(
                Account { mint, owner: recipient, state: AccountState::Initialized, ..Account::default() },
                &mut data,
            )
            .unwrap();
            accounts.push(account(ata, token_program, data, true));
        }
        (V5FillInput { recipient, output_token: mint, min_output_amount: AMOUNT }, accounts)
    }

    #[test]
    fn fill_loader_preserves_delivery_for_both_token_programs() {
        for token_program in [anchor_spl::token::ID, anchor_spl::token_2022::ID] {
            for in_place in [true, false] {
                let (input, accounts) = fixture(token_program, in_place);
                let loaded = V5FillAccounts::load(&accounts, &input, &SUBMITTER, &[0; 32]).unwrap();
                assert_eq!(loaded.transfer.from.key() == loaded.transfer.to.key(), in_place);
                assert_eq!(loaded.transfer.authority.key(), V5_FILL_DELEGATE);
                assert_eq!(loaded.mint_decimals, 6);
                assert_eq!(loaded.token_program.key(), token_program);
            }
        }
    }

    #[test]
    fn reused_vault_still_requires_valid_token_state() {
        for token_program in [anchor_spl::token::ID, anchor_spl::token_2022::ID] {
            for defect in ["missing", "readonly", "program", "mint", "authority", "malformed"] {
                let (input, mut accounts) = fixture(token_program, true);
                let mut expected = "InvalidTokenAccount";
                match defect {
                    "missing" => {
                        accounts.remove(0);
                        expected = "MissingAccount";
                    }
                    "readonly" => {
                        accounts[0].is_writable = false;
                        expected = "InvalidAccountMutability";
                    }
                    "program" => accounts[0].owner = &anchor_lang::system_program::ID,
                    "malformed" => accounts[0] = account(accounts[0].key(), token_program, vec![0; 3], true),
                    _ => {
                        let mut token = Account::unpack(&accounts[0].try_borrow_data().unwrap()).unwrap();
                        match defect {
                            "mint" => token.mint = Pubkey::new_unique(),
                            "authority" => token.owner = Pubkey::new_unique(),
                            _ => unreachable!(),
                        }
                        Account::pack(token, &mut accounts[0].try_borrow_mut_data().unwrap()).unwrap();
                    }
                }
                match V5FillAccounts::load(&accounts, &input, &SUBMITTER, &[0; 32])
                    .err()
                    .unwrap()
                {
                    anchor_lang::error::Error::AnchorError(error) => assert_eq!(error.error_name, expected, "{defect}"),
                    error => panic!("{defect}: {error}"),
                }
            }
        }
    }
}
