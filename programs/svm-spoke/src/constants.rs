use anchor_lang::prelude::*;

pub const DISCRIMINATOR_SIZE: usize = 8;

// Circle CCTP V2 MessageTransmitter program. Only V2 messages can be received as Circle is deprecating CCTP V1.
pub const MESSAGE_TRANSMITTER_PROGRAM_ID: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");

// CCTP V2 finality threshold at which Circle attests only after the source chain has reached hard finality:
// https://github.com/circlefin/solana-cctp-contracts/blob/master/programs/v2/message-transmitter-v2/src/instructions/receive_message.rs
pub const FINALITY_THRESHOLD_FINALIZED: u32 = 2000;

// One year in seconds. If exclusivityParameter is set to a value less than this, then the emitted exclusivityDeadline
// in a deposit event will be set to the current time plus this value.
pub const MAX_EXCLUSIVITY_PERIOD_SECONDS: u32 = 31_536_000;

pub const ZERO_DEPOSIT_ID: [u8; 32] = [0u8; 32];
