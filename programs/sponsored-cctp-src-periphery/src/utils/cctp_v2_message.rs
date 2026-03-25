use anchor_lang::prelude::*;

use crate::{error::CctpBurnMessageV2Error, instructions::ReclaimEventAccountParams};

// Required CCTPv2 message constants from https://developers.circle.com/cctp/technical-guide#message-header
const VERSION_INDEX: usize = 0;
const VERSION_LEN: usize = 4; // uint32
const SUPPORTED_VERSION: u32 = 1;
const NONCE_INDEX: usize = 12;
const NONCE_LEN: usize = 32; // bytes32
const FINALITY_THRESHOLD_EXECUTED_INDEX: usize = 144;
const FINALITY_THRESHOLD_EXECUTED_LEN: usize = 4; // uint32
const MESSAGE_BODY_INDEX: usize = 148;

// Required CCTPv2 message body constants from https://developers.circle.com/cctp/technical-guide#message-body
const BODY_VERSION_INDEX: usize = MESSAGE_BODY_INDEX + 0;
const BODY_VERSION_LEN: usize = 4; // uint32
const SUPPORTED_BODY_VERSION: u32 = 1;
const FEE_EXECUTED_INDEX: usize = MESSAGE_BODY_INDEX + 164;
const FEE_EXECUTED_LEN: usize = 32; // uint256
const EXPIRATION_BLOCK_INDEX: usize = MESSAGE_BODY_INDEX + 196;
const EXPIRATION_BLOCK_LEN: usize = 32; // uint256
const HOOK_DATA_INDEX: usize = MESSAGE_BODY_INDEX + 228;

pub fn build_destination_message(source_message: &[u8], params: &ReclaimEventAccountParams) -> Result<Vec<u8>> {
    if source_message.len() < HOOK_DATA_INDEX {
        return err!(CctpBurnMessageV2Error::MalformedMessage);
    }

    let message_version = u32::from_be_bytes(
        source_message[VERSION_INDEX..VERSION_INDEX + VERSION_LEN]
            .try_into()
            .unwrap(), // Safe as we check the length above.
    );
    if message_version != SUPPORTED_VERSION {
        return err!(CctpBurnMessageV2Error::InvalidMessageVersion);
    }

    let message_body_version = u32::from_be_bytes(
        source_message[BODY_VERSION_INDEX..BODY_VERSION_INDEX + BODY_VERSION_LEN]
            .try_into()
            .unwrap(), // Safe as we check the length above.
    );
    if message_body_version != SUPPORTED_BODY_VERSION {
        return err!(CctpBurnMessageV2Error::InvalidMessageBodyVersion);
    }

    let mut destination_message = source_message.to_vec();

    // Overwrite parameters that are changed in the destination message.
    destination_message[NONCE_INDEX..NONCE_INDEX + NONCE_LEN].copy_from_slice(&params.nonce);
    destination_message
        [FINALITY_THRESHOLD_EXECUTED_INDEX..FINALITY_THRESHOLD_EXECUTED_INDEX + FINALITY_THRESHOLD_EXECUTED_LEN]
        .copy_from_slice(&params.finality_threshold_executed);
    destination_message[FEE_EXECUTED_INDEX..FEE_EXECUTED_INDEX + FEE_EXECUTED_LEN]
        .copy_from_slice(&params.fee_executed);
    destination_message[EXPIRATION_BLOCK_INDEX..EXPIRATION_BLOCK_INDEX + EXPIRATION_BLOCK_LEN]
        .copy_from_slice(&params.expiration_block);

    Ok(destination_message)
}
