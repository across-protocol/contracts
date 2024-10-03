use anchor_lang::prelude::*;

use crate::RelayerRefundLeaf;

#[account]
#[derive(InitSpace)]
pub struct InstructionData {
    #[max_len(0)]
    pub data: Vec<u8>,
}

#[account]
#[derive(InitSpace)]
pub struct ExecuteRelayerRefundLeafParams {
    pub root_bundle_id: u32,
    pub relayer_refund_leaf: RelayerRefundLeaf,
    #[max_len(0)]
    pub proof: Vec<[u8; 32]>,
}
