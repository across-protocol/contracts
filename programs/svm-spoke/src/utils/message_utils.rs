use anchor_lang::{
    prelude::*,
    solana_program::{instruction::Instruction, keccak, program::invoke, system_instruction},
};

use crate::{constants::DISCRIMINATOR_SIZE, error::AcrossPlusError};

// Sha256(global:handle_v3_across_message)[..8];
const HANDLE_V3_ACROSS_MESSAGE_DISCRIMINATOR: [u8; 8] = (0x838d3447103bc45c_u64).to_be_bytes();

#[derive(AnchorDeserialize)]
pub struct AcrossPlusMessage {
    pub handler: Pubkey,
    pub read_only_len: u8,
    pub value_amount: u64,
    pub accounts: Vec<Pubkey>,
    pub handler_message: Vec<u8>,
}

pub fn invoke_handler<'info>(
    relayer: &AccountInfo<'info>,
    remaining_accounts: &[AccountInfo<'info>],
    message: &Vec<u8>,
) -> Result<()> {
    let message =
        AcrossPlusMessage::deserialize(&mut &message[..]).map_err(|_| AcrossPlusError::MessageDidNotDeserialize)?;

    // First remaining account is the handler and the rest are accounts to be passed to the message handler.
    let message_accounts_len = message.accounts.len();
    if remaining_accounts.len() != message_accounts_len + 1 {
        return err!(AcrossPlusError::InvalidMessageKeyLength);
    }
    if (message.read_only_len as usize) > message_accounts_len {
        return err!(AcrossPlusError::InvalidReadOnlyKeyLength);
    }
    let handler = &remaining_accounts[0];
    let account_infos = &remaining_accounts[1..];

    if handler.key() != message.handler {
        return err!(AcrossPlusError::InvalidMessageHandler);
    }

    // Populate accounts for the invoked message handler CPI.
    let mut accounts = Vec::with_capacity(message_accounts_len);
    for (i, message_account_key) in message.accounts.into_iter().enumerate() {
        if account_infos[i].key() != message_account_key {
            return Err(Error::from(AcrossPlusError::InvalidMessageAccountKey)
                .with_pubkeys((account_infos[i].key(), message_account_key)));
        }

        // Writable accounts must be passed first. This enforces the same write permissions as set in the message. Note
        // that this would fail if any of mutable FillV3Relay / ExecuteSlowRelayLeaf accounts are passed as read-only
        // in the bridged message as the calling client deduplicates the accounts and applies maximum required
        // privileges. Though it is unlikely that any practical application would require this.
        // We also explicitly disable all signer privileges for all the accounts to protect the relayer from being
        // drained of funds in the inner instructions.
        match i < message_accounts_len - (message.read_only_len as usize) {
            true => {
                if !account_infos[i].is_writable {
                    return Err(Error::from(AcrossPlusError::NotWritableMessageAccountKey)
                        .with_account_name(format!("{}", message_account_key)));
                }
                accounts.push(AccountMeta::new(message_account_key, false));
            }
            false => {
                if account_infos[i].is_writable {
                    return Err(Error::from(AcrossPlusError::NotReadOnlyMessageAccountKey)
                        .with_account_name(format!("{}", message_account_key)));
                }
                accounts.push(AccountMeta::new_readonly(message_account_key, false));
            }
        }
    }

    // Transfer value amount from the relayer to the first account in the message accounts.
    // Note that the depositor is responsible to make sure that after invoking the handler the recipient account will
    // not hold any balance that is below its rent-exempt threshold, otherwise the fill would fail.
    if message.value_amount > 0 {
        let recipient_account = account_infos.first().ok_or(AcrossPlusError::MissingValueRecipientKey)?;
        let transfer_ix = system_instruction::transfer(&relayer.key(), &recipient_account.key(), message.value_amount);
        invoke(&transfer_ix, &[relayer.to_account_info(), recipient_account.to_account_info()])?;
    }

    // The data will hold the handler ix discriminator and raw handler message bytes (including 4 bytes for the length).
    let mut data = Vec::with_capacity(DISCRIMINATOR_SIZE + 4 + message.handler_message.len());
    data.extend_from_slice(&HANDLE_V3_ACROSS_MESSAGE_DISCRIMINATOR);
    AnchorSerialize::serialize(&message.handler_message, &mut data)?;

    let instruction = Instruction { program_id: message.handler, accounts, data };

    invoke(&instruction, account_infos)?;

    Ok(())
}

pub fn hash_non_empty_message(message: &Vec<u8>) -> [u8; 32] {
    match message.len() {
        0 => [0u8; 32],
        _ => keccak::hash(message).to_bytes(),
    }
}
