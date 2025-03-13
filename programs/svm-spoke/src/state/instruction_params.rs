use anchor_lang::prelude::*;

use crate::{RelayData, RelayerRefundLeaf, SlowFill};

#[account]
pub struct ExecuteRelayerRefundLeafParams {
    pub root_bundle_id: u32,                    // ID of the root bundle to be used.
    pub relayer_refund_leaf: RelayerRefundLeaf, // Leaf to be verified against the proof and instruct bundle execution.
    pub proof: Vec<[u8; 32]>,                   // Proof to verify the leaf's inclusion in relayer refund merkle tree.
}

#[account]
pub struct FillRelayParams {
    pub relay_data: RelayData,
    pub repayment_chain_id: u64,
    pub repayment_address: Pubkey,
}

#[account]
pub struct RequestSlowFillParams {
    pub relay_data: RelayData,
}

#[account]
pub struct ExecuteSlowRelayLeafParams {
    pub slow_fill_leaf: SlowFill,
    pub root_bundle_id: u32,
    pub proof: Vec<[u8; 32]>,
}
