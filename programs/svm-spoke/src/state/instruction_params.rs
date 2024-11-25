use anchor_lang::prelude::*;

use crate::{RelayerRefundLeaf, V3RelayData};

#[account]
#[derive(InitSpace)]
pub struct ExecuteRelayerRefundLeafParams {
    pub root_bundle_id: u32,
    pub relayer_refund_leaf: RelayerRefundLeaf,
    #[max_len(0)]
    pub proof: Vec<[u8; 32]>,
}

#[account]
#[derive(InitSpace)]
pub struct FillV3RelayParams {
    pub relay_data: V3RelayData,
    pub repayment_chain_id: u64,
    pub repayment_address: Pubkey,
}

#[account]
#[derive(InitSpace)]
pub struct RequestV3SlowFillParams {
    pub relay_data: V3RelayData,
}
