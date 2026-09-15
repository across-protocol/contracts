use anchor_lang::prelude::*;

use crate::{common::RelayData, constants::BIPS_DENOMINATOR, error::V5Error};

pub const V5_SIGNATURE_LEN: usize = 65;

/// Version 1 of the Gateway-attested context prepended to every adapter call.
///
/// Field order and widths are part of the Gateway dispatch ABI. A context-layout change requires a new Gateway
/// dispatch ABI and adapter entrypoint rather than a new [`V5AdapterInput`] variant.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct GatewayContextV1 {
    pub step_id: [u8; 32],
    pub path_id: [u8; 32],
    pub submitter: Pubkey,
}

/// Committed input for an Across V5 adapter call.
///
/// `V5` is the Across protocol generation; each variant's `V1` is its SVM wire-schema revision. Borsh discriminants
/// are frozen as `DepositV1 = 0` and `FillV1 = 1`. Append a new versioned variant when one payload changes; never
/// reorder existing variants. A safe old variant may remain accepted while in-flight inputs drain, while an unsafe
/// variant can be rejected immediately.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum V5AdapterInput {
    DepositV1(AcrossDepositInput),
    FillV1(V5FillInput),
}

/// Literal uses the committed `input_amount`. Balance-relative mode resolves `bips` of the canonical Gateway input
/// vault's live token amount, rounded down, and later enforces the committed amount as a floor. Gateway vaults are
/// shared per mint, not isolated per execution, so the continuing tape must leave no residual balance; Gateway does
/// not currently enforce that net-zero settlement invariant.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub enum V5InputAmountMode {
    Literal,
    InputVaultBalance { bips: u16 },
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct V5DepositModificationRules {
    pub authority: [u8; 20],
    pub allow_output_amount: bool,
    pub allow_exclusive_relayer: bool,
}

impl V5DepositModificationRules {
    pub fn jit_enabled(&self) -> bool {
        self.authority != [0u8; 20] || self.allow_output_amount || self.allow_exclusive_relayer
    }
}

/// Canonical Across deposit fields. `output_amount` remains an EVM uint256 word; SVM-native amounts and non-EVM
/// chain IDs are width-bounded to u64.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AcrossDepositParams {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: [u8; 32],
    pub destination_chain_id: u64,
    pub exclusive_relayer: Pubkey,
    pub deposit_nonce: u64,
    pub quote_timestamp: u32,
    pub fill_deadline: u32,
    pub exclusivity_parameter: u32,
}

/// Path-committed source-deposit input, shaped like the EVM `AcrossDepositInput` compatibility surface.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AcrossDepositInput {
    pub deposit_params: AcrossDepositParams,
    pub dst_step_id: [u8; 32],
    pub input_amount_mode: V5InputAmountMode,
    pub modification_rules: V5DepositModificationRules,
}

/// JIT payload for Deposit mode. The signature is fixed `r[32] || s[32] || v[1]` rather than a length-prefixed vec.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AcrossDepositJitParams {
    pub new_output_amount: [u8; 32],
    pub new_exclusive_relayer: Pubkey,
    pub signature: [u8; V5_SIGNATURE_LEN],
}

/// Destination acceptance bounds. Unlike the EVM executor-mode input, the SVM adapter omits a callback message
/// because V5 adapter fills do not execute recipient callbacks.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V5FillInput {
    pub recipient: Pubkey,
    pub output_token: Pubkey,
    pub min_output_amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V5FillJit {
    pub relay_data: RelayData,
    pub repayment_chain_id: u64,
    pub repayment_address: Pubkey,
}

pub(crate) fn decode_strict<T: AnchorDeserialize>(data: &[u8]) -> Result<T> {
    T::try_from_slice(data).map_err(|_| error!(V5Error::InvalidWireFormat))
}

pub fn decode_v5_adapter_input(data: &[u8]) -> Result<V5AdapterInput> {
    decode_strict(data)
}

pub fn resolve_v5_input_amount(mode: V5InputAmountMode, committed_amount: u64, vault_balance: u64) -> Result<u64> {
    let amount = match mode {
        V5InputAmountMode::Literal => committed_amount,
        V5InputAmountMode::InputVaultBalance { bips } => {
            require!(bips <= BIPS_DENOMINATOR, V5Error::InvalidWireFormat);
            (u128::from(vault_balance) * u128::from(bips) / u128::from(BIPS_DENOMINATOR)) as u64
        }
    };
    require!(amount >= committed_amount, V5Error::ResolvedInputAmountBelowCommitted);
    Ok(amount)
}
