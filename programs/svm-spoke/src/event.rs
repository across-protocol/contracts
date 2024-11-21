use anchor_lang::prelude::*;

// use ethereum_types::U256;
// // Wrapper struct for U256
// pub struct U256Wrapper(pub U256);

// impl anchor_lang::AnchorSerialize for U256Wrapper {
//     fn serialize<W: std::io::Write>(&self, writer: &mut W) -> std::io::Result<()> {
//         let bytes = U256::to_little_endian(&self.0); // Get the little-endian byte array
//         writer.write_all(&bytes) // Write the byte array to the writer
//     }
// }

// impl anchor_lang::AnchorDeserialize for U256Wrapper {
//     fn deserialize(buf: &mut &[u8]) -> std::io::Result<Self> {
//         let mut bytes = [0u8; 32];
//         bytes.copy_from_slice(&buf[..32]); // Copy the first 32 bytes
//         let u256 = U256::from_big_endian(&bytes); // Convert from big-endian byte array
//         Ok(U256Wrapper(u256))
//     }

//     fn deserialize_reader<R: std::io::Read>(reader: &mut R) -> std::io::Result<Self> {
//         let mut bytes = [0u8; 32];
//         reader.read_exact(&mut bytes)?;
//         let u256 = U256::from_big_endian(&bytes); // Convert from big-endian byte array
//         Ok(U256Wrapper(u256))
//     }
// }

// #[cfg(feature = "idl-build")]
// impl anchor_lang::IdlBuild for U256Wrapper {
//     fn create_type() -> Option<IdlTypeDef> {
//         Some(IdlTypeDef {
//             name: "U256Wrapper".into(),
//             ty: IdlTypeDefTy::Struct {
//                 fields: Some(IdlDefinedFields::Named(vec![IdlField {
//                     name: "value".into(),
//                     ty: IdlType::Array(Box::new(IdlType::U8), 32),
//                     docs: Default::default(),
//                 }])),
//             },
//             docs: Default::default(),
//             generics: Default::default(),
//             serialization: Default::default(),
//             repr: Default::default(),
//         })
//     }

//     fn get_full_path() -> String {
//         "U256Wrapper".to_string()
//     }

//     fn insert_types(types: &mut std::collections::HashMap<String, IdlTypeDef>) {
//         types.insert(
//             "U256Wrapper".to_string(),
//             IdlTypeDef {
//                 name: "U256Wrapper".into(),
//                 ty: IdlTypeDefTy::Struct {
//                     fields: Some(IdlDefinedFields::Named(vec![IdlField {
//                         name: "value".into(),
//                         ty: IdlType::Array(Box::new(IdlType::U8), 32),
//                         docs: Default::default(),
//                     }])),
//                 },
//                 docs: Default::default(),
//                 generics: Default::default(),
//                 serialization: Default::default(),
//                 repr: Default::default(),
//             },
//         );
//     }
// }

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
    pub deposit_id: String,
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
    pub updated_message: Vec<u8>,
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
    pub deposit_id: u32,
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub exclusive_relayer: Pubkey,
    pub relayer: Pubkey,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub message: Vec<u8>,
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
    pub deposit_id: u32,
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub exclusive_relayer: Pubkey,
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub message: Vec<u8>,
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

// TODO: update the name of this to EmergencyDeletedRootBundle and in EVM.
#[event]
pub struct EmergencyDeleteRootBundle {
    pub root_bundle_id: u32,
}

#[event]
pub struct BridgedToHubPool {
    pub amount: u64,
    pub mint: Pubkey,
}
