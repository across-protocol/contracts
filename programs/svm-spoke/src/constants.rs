use anchor_lang::prelude::*;

pub const DISCRIMINATOR_SIZE: usize = 8;

// Circle CCTP V2 MessageTransmitter program. Only V2 messages can be received as Circle is deprecating CCTP V1.
pub const MESSAGE_TRANSMITTER_PROGRAM_ID: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");

// One year in seconds. If exclusivityParameter is set to a value less than this, then the emitted exclusivityDeadline
// in a deposit event will be set to the current time plus this value.
pub const MAX_EXCLUSIVITY_PERIOD_SECONDS: u32 = 31_536_000;

pub const BIPS_DENOMINATOR: u16 = 10_000;

pub const V5_DEPOSIT_DELEGATE_SEED: &[u8] = b"v5_deposit_delegate";
pub const V5_DEPOSIT_DELEGATE: Pubkey = pubkey!("8DWnJFMBTSDYWsUUSqna9tx9LJbU1yUfq7jTiPJDf8sX");
pub const V5_DEPOSIT_DELEGATE_BUMP: u8 = 252;
pub const V5_FILL_DELEGATE_SEED: &[u8] = b"v5_fill_delegate";
pub const V5_FILL_DELEGATE: Pubkey = pubkey!("D27f3mVXRL6N3bgja49UWLQu7kt57sy1aZYy7ZEwdxn1");
pub const V5_FILL_DELEGATE_BUMP: u8 = 252;
pub const V5_FILL_PAYER_SEED: &[u8] = b"v5_fill_payer";
pub const FILL_STATUS_SEED: &[u8] = b"fills";

// Mirrored from the Gateway dispatch ABI. Keep these local: Gateway and svm-spoke intentionally use different
// Anchor versions and must not acquire a cross-repository Rust dependency.
pub const GATEWAY_PROGRAM_ID: Pubkey = pubkey!("pVs6PJ3ofdqPyDhCXXdVW7waG6oNnwKQBKtuM6Mi6JP");
pub const GATEWAY_DISPATCH_AUTHORITY_SEED: &[u8] = b"dispatch_authority";
pub const GATEWAY_DISPATCH_AUTHORITY: Pubkey = pubkey!("8xGrXYfSb2QLHrPkBZ39DLocxjVGQLLbo9B8PyAcARQF");
pub const GATEWAY_DISPATCH_AUTHORITY_BUMP: u8 = 255;
pub const GATEWAY_VAULT_AUTHORITY_SEED: &[u8] = b"vault_authority";
pub const GATEWAY_VAULT_AUTHORITY: Pubkey = pubkey!("GLU32tN1sN6XHFcSgx1VNa58GqdjZzx6BHnZ4Y8B5NVH");
pub const GATEWAY_VAULT_AUTHORITY_BUMP: u8 = 255;

// Magic prefix tagging a deposit message as an Across V5 witness: `message = V5_MAGIC_PREFIX || stepId`, where
// stepId is the Merkle root of the Gateway execution allowed to consume the deposit. V5-tagged deposits are only
// consumable through Gateway-context-checked V5 fill entrypoints, so all V3 settlement paths must reject them.
// keccak256("AcrossV5MessagePrefix.V1"); must match the EVM SpokePool constant byte-for-byte.
pub const V5_MAGIC_PREFIX: [u8; 32] = [
    0x89, 0xae, 0x4b, 0xc7, 0x59, 0x15, 0x26, 0x5a, 0x3f, 0x10, 0xe9, 0x26, 0xc3, 0x89, 0x4a, 0x29, 0x53, 0x4f, 0x1d,
    0x63, 0x62, 0xee, 0x89, 0x59, 0xcb, 0x0e, 0x5b, 0xe0, 0x0f, 0x35, 0x27, 0xfd,
];
