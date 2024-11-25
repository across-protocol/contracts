use anchor_lang::prelude::*;

// Admin events
#[event]
pub struct SetXDomainAdmin {
    pub new_admin: Pubkey,
}

#[event]
pub struct PausedDeposits {
    pub is_paused: bool,
}

#[event]
pub struct PausedFills {
    pub is_paused: bool,
}

#[event]
pub struct EnabledDepositRoute {
    pub origin_token: Pubkey,
    pub destination_chain_id: u64,
    pub enabled: bool,
}

#[event]
pub struct RelayedRootBundle {
    pub root_bundle_id: u32,
    pub relayer_refund_root: [u8; 32],
    pub slow_relay_root: [u8; 32],
}

// Deposit events
#[event]
pub struct V3FundsDeposited {
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub destination_chain_id: u64,
    pub deposit_id: [u8; 32],
    pub quote_timestamp: u32,
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub exclusive_relayer: Pubkey,
    pub message: Vec<u8>,
}

// Fill events
#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq)]
pub enum FillType {
    FastFill,
    ReplacedSlowFill,
    SlowFill,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V3RelayExecutionEventInfo {
    pub updated_recipient: Pubkey,
    pub updated_message_hash: [u8; 32],
    pub updated_output_amount: u64,
    pub fill_type: FillType,
}

#[event]
pub struct FilledV3Relay {
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub repayment_chain_id: u64,
    pub origin_chain_id: u64,
    pub deposit_id: [u8; 32],
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub exclusive_relayer: Pubkey,
    pub relayer: Pubkey,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    // TODO: update EVM implementation to use message_hash in all fill related events.
    pub message_hash: [u8; 32],
    pub relay_execution_info: V3RelayExecutionEventInfo,
}

// Slow fill events
#[event]
pub struct RequestedV3SlowFill {
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub origin_chain_id: u64,
    pub deposit_id: [u8; 32],
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub exclusive_relayer: Pubkey,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub message_hash: [u8; 32],
}

// Relayer refund events
#[event]
pub struct ExecutedRelayerRefundRoot {
    pub amount_to_return: u64,
    pub chain_id: u64,
    pub refund_amounts: Vec<u64>,
    pub root_bundle_id: u32,
    pub leaf_id: u32,
    pub l2_token_address: Pubkey,
    pub refund_addresses: Vec<Pubkey>,
    pub deferred_refunds: bool,
    pub caller: Pubkey,
}

#[event]
pub struct ClaimedRelayerRefund {
    pub l2_token_address: Pubkey,
    pub claim_amount: u64,
    pub refund_address: Pubkey,
}

#[event]
pub struct EmergencyDeletedRootBundle {
    pub root_bundle_id: u32,
}

#[event]
pub struct BridgedToHubPool {
    pub amount: u64,
    pub mint: Pubkey,
}
