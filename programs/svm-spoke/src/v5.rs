//! Wire, cryptographic, and PDA helpers for the Gateway-facing V5 adapter. Source deposits are live in wire version
//! 1; the reserved fill branch remains closed until its destination behavior lands.

use anchor_lang::{
    prelude::*,
    solana_program::{hash::hash, keccak, secp256k1_recover::secp256k1_recover},
};

use crate::{
    common::RelayData,
    constants::{
        BIPS_DENOMINATOR, FILL_STATUS_SEED, GATEWAY_ADAPTER_EXECUTE_V5_PREIMAGE, GATEWAY_DISPATCH_AUTHORITY_SEED,
        GATEWAY_PROGRAM_ID, GATEWAY_VAULT_AUTHORITY_SEED, V5_ADAPTER_WIRE_VERSION, V5_FILL_DELEGATE_SEED,
        V5_FILL_PAYER_SEED, V5_SOURCE_DELEGATE_SEED,
    },
    error::V5Error,
    ID,
};

pub const V5_SIGNATURE_LEN: usize = 65;
pub const V5_PARAM_MODIFICATION_NAME: &[u8] = b"ACXV.AcrossDepositDelegateAdapter.V1";
const SECP256K1_HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x5d, 0x57, 0x6e,
    0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
];

/// Gateway-attested values prepended to every adapter call. Field order and widths mirror Gateway `CtxValues`.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct V5GatewayContext {
    pub step_id: [u8; 32],
    pub path_id: [u8; 32],
    pub submitter: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V5AdapterInput {
    pub version: u8,
    pub mode: V5AdapterMode,
}

/// Borsh enum discriminants are frozen as Deposit=0 and Fill=1.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum V5AdapterMode {
    Deposit(AcrossDepositInput),
    Fill(V5FillInput),
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
    pub fn validate(&self) -> Result<()> {
        let has_authority = self.authority != [0u8; 20];
        let has_permission = self.allow_output_amount || self.allow_exclusive_relayer;
        // SVM v1 intentionally requires an authority for any JIT permission. The EVM adapter permits authority-less
        // JIT when permission bits are set, so route builders must not reuse that EVM-only shape for SVM.
        require!(has_authority == has_permission, V5Error::InvalidParamModificationRules);
        Ok(())
    }

    pub fn jit_enabled(&self) -> bool {
        self.authority != [0u8; 20]
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

/// Destination acceptance bounds. Adapter mode requires `message` to be empty; retaining the field keeps the
/// semantic V5FillInput shape explicit and makes a non-empty callback fail closed.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V5FillInput {
    pub recipient: Pubkey,
    pub output_token: Pubkey,
    pub min_output_amount: u64,
    pub message: Vec<u8>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V5FillJit {
    pub relay_data: RelayData,
    pub repayment_chain_id: u64,
    pub repayment_address: Pubkey,
}

fn decode_strict<T: AnchorDeserialize>(data: &[u8]) -> Result<T> {
    let mut remaining = data;
    let decoded = T::deserialize(&mut remaining).map_err(|_| error!(V5Error::InvalidWireFormat))?;
    require!(remaining.is_empty(), V5Error::InvalidWireFormat);
    Ok(decoded)
}

pub fn decode_v5_adapter_input(data: &[u8]) -> Result<V5AdapterInput> {
    let (&version, body) = data.split_first().ok_or_else(|| error!(V5Error::InvalidWireFormat))?;
    require_eq!(version, V5_ADAPTER_WIRE_VERSION, V5Error::UnsupportedVersion);
    let input = V5AdapterInput { version, mode: decode_strict(body)? };
    match &input.mode {
        V5AdapterMode::Deposit(deposit) => {
            if let V5InputAmountMode::InputVaultBalance { bips } = deposit.input_amount_mode {
                require!(bips <= BIPS_DENOMINATOR, V5Error::InvalidWireFormat);
            }
            deposit.modification_rules.validate()?;
        }
        V5AdapterMode::Fill(fill) => require!(fill.message.is_empty(), V5Error::InvalidWireFormat),
    }
    Ok(input)
}

pub fn decode_v5_deposit_jit(deposit: &AcrossDepositInput, data: &[u8]) -> Result<Option<AcrossDepositJitParams>> {
    deposit.modification_rules.validate()?;
    if deposit.modification_rules.jit_enabled() {
        Ok(Some(decode_strict(data)?))
    } else {
        require!(data.is_empty(), V5Error::InvalidWireFormat);
        Ok(None)
    }
}

pub fn decode_v5_fill_jit(data: &[u8]) -> Result<V5FillJit> {
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

pub fn require_v5_delegate_allowance(allowance: u64, amount: u64) -> Result<()> {
    require!(allowance >= amount, V5Error::InsufficientDelegateAllowance);
    Ok(())
}

fn u64_to_evm_uint(value: u64) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[24..].copy_from_slice(&value.to_be_bytes());
    word
}

/// `syntheticNonce = keccak256(submitter || pathId || uint256(depositNonce))` then
/// `depositId = keccak256(executorProgramId || depositor || syntheticNonce)`.
pub fn derive_v5_deposit_id(
    executor_program_id: &Pubkey,
    submitter: &Pubkey,
    path_id: &[u8; 32],
    depositor: &Pubkey,
    deposit_nonce: u64,
) -> [u8; 32] {
    let nonce = u64_to_evm_uint(deposit_nonce);
    let synthetic_nonce = keccak::hashv(&[submitter.as_ref(), path_id, &nonce]).to_bytes();
    keccak::hashv(&[executor_program_id.as_ref(), depositor.as_ref(), &synthetic_nonce]).to_bytes()
}

pub fn v5_param_modification_domain(gateway_program_id: &Pubkey) -> [u8; 32] {
    let name_hash = keccak::hash(V5_PARAM_MODIFICATION_NAME).to_bytes();
    // EVM `abi.encode(bytes32,address)` is two 32-byte words. The SVM Gateway identity is already one word.
    keccak::hashv(&[&name_hash, gateway_program_id.as_ref()]).to_bytes()
}

/// EVM-compatible packed digest over fixed 32-byte words. `new_output_amount` is already a uint256 big-endian word.
pub fn v5_param_modification_digest(
    gateway_program_id: &Pubkey,
    path_id: &[u8; 32],
    deposit_nonce: u64,
    new_output_amount: &[u8; 32],
    new_exclusive_relayer: &Pubkey,
) -> [u8; 32] {
    let domain = v5_param_modification_domain(gateway_program_id);
    let nonce = u64_to_evm_uint(deposit_nonce);
    keccak::hashv(&[
        &domain,
        path_id,
        &nonce,
        new_output_amount,
        new_exclusive_relayer.as_ref(),
    ])
    .to_bytes()
}

/// Recover the 20-byte EVM authority from `r || s || v`. Only EVM-canonical v=27/28 and low-s signatures pass.
pub fn recover_v5_authority(digest: &[u8; 32], signature: &[u8; V5_SIGNATURE_LEN]) -> Result<[u8; 20]> {
    let recovery_id = match signature[64] {
        27 | 28 => signature[64] - 27,
        _ => return err!(V5Error::InvalidParamModificationSignature),
    };
    require!(signature[32..64] <= SECP256K1_HALF_ORDER[..], V5Error::InvalidParamModificationSignature);
    let public_key = secp256k1_recover(digest, recovery_id, &signature[..64])
        .map_err(|_| error!(V5Error::InvalidParamModificationSignature))?;
    let hashed = keccak::hash(public_key.to_bytes().as_ref()).to_bytes();
    Ok(hashed[12..].try_into().unwrap())
}

pub fn verify_v5_authority(
    expected_authority: &[u8; 20],
    digest: &[u8; 32],
    signature: &[u8; V5_SIGNATURE_LEN],
) -> Result<()> {
    require!(*expected_authority != [0u8; 20], V5Error::InvalidParamModificationRules);
    require!(
        recover_v5_authority(digest, signature)? == *expected_authority,
        V5Error::InvalidParamModificationSignature
    );
    Ok(())
}

/// Verify and apply only the committed JIT permissions. Output-amount changes are improvement-only; unpermitted
/// proposed values remain signature-bound but are ignored, matching the EVM adapter.
pub fn resolve_v5_deposit_modifications(
    input: &AcrossDepositInput,
    jit: &AcrossDepositJitParams,
    gateway_program_id: &Pubkey,
    path_id: &[u8; 32],
) -> Result<([u8; 32], Pubkey)> {
    input.modification_rules.validate()?;
    require!(input.modification_rules.jit_enabled(), V5Error::InvalidParamModificationRules);
    let deposit = &input.deposit_params;
    let digest = v5_param_modification_digest(
        gateway_program_id,
        path_id,
        deposit.deposit_nonce,
        &jit.new_output_amount,
        &jit.new_exclusive_relayer,
    );
    verify_v5_authority(&input.modification_rules.authority, &digest, &jit.signature)?;

    let output_amount = if input.modification_rules.allow_output_amount {
        require!(jit.new_output_amount >= deposit.output_amount, V5Error::ParamModificationNotAnImprovement);
        jit.new_output_amount
    } else {
        deposit.output_amount
    };
    let exclusive_relayer = if input.modification_rules.allow_exclusive_relayer {
        jit.new_exclusive_relayer
    } else {
        deposit.exclusive_relayer
    };
    Ok((output_amount, exclusive_relayer))
}

pub fn gateway_adapter_discriminator() -> [u8; 8] {
    hash(GATEWAY_ADAPTER_EXECUTE_V5_PREIMAGE).to_bytes()[..8]
        .try_into()
        .unwrap()
}

pub fn derive_gateway_dispatch_authority() -> (Pubkey, u8) {
    Pubkey::find_program_address(&[GATEWAY_DISPATCH_AUTHORITY_SEED, ID.as_ref()], &GATEWAY_PROGRAM_ID)
}

pub fn derive_gateway_vault_authority() -> (Pubkey, u8) {
    Pubkey::find_program_address(&[GATEWAY_VAULT_AUTHORITY_SEED], &GATEWAY_PROGRAM_ID)
}

pub fn derive_v5_source_delegate() -> (Pubkey, u8) {
    Pubkey::find_program_address(&[V5_SOURCE_DELEGATE_SEED], &ID)
}

pub fn derive_v5_fill_delegate() -> (Pubkey, u8) {
    Pubkey::find_program_address(&[V5_FILL_DELEGATE_SEED], &ID)
}

pub fn derive_v5_fill_payer(submitter: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[V5_FILL_PAYER_SEED, submitter.as_ref()], &ID)
}

pub fn derive_fill_status(relay_hash: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[FILL_STATUS_SEED, relay_hash], &ID)
}

pub fn require_gateway_dispatch_authority(account: &AccountInfo) -> Result<()> {
    let (expected, _) = derive_gateway_dispatch_authority();
    require!(account.is_signer && *account.key == expected, V5Error::InvalidDispatchAuthority);
    Ok(())
}

/// Resolve branch-specific accounts by authenticated key, never by submitter-controlled position.
pub fn find_v5_account<'a, 'info>(
    accounts: &'a [AccountInfo<'info>],
    expected: &Pubkey,
    writable: bool,
) -> Result<&'a AccountInfo<'info>> {
    let account = accounts
        .iter()
        .find(|account| account.key == expected)
        .ok_or_else(|| error!(V5Error::MissingAccount))?;
    require!(!writable || account.is_writable, V5Error::InvalidAccountMutability);
    Ok(account)
}

#[cfg(test)]
mod tests {
    use super::*;
    use anchor_lang::Discriminator;
    use serde_json::Value;
    use std::str::FromStr;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../fixtures/v5_adapter_v1.json")).unwrap()
    }

    fn bytes(value: &Value, path: &str) -> Vec<u8> {
        hex::decode(value.pointer(path).unwrap().as_str().unwrap().trim_start_matches("0x")).unwrap()
    }

    fn array<const N: usize>(value: &Value, path: &str) -> [u8; N] {
        bytes(value, path).try_into().unwrap()
    }

    fn serialize<T: AnchorSerialize>(value: &T) -> Vec<u8> {
        let mut bytes = Vec::new();
        value.serialize(&mut bytes).unwrap();
        bytes
    }

    fn assert_error_name<T>(result: Result<T>, expected: &str) {
        match result.err().unwrap() {
            anchor_lang::error::Error::AnchorError(error) => assert_eq!(error.error_name, expected),
            _ => panic!("expected Anchor error"),
        }
    }

    #[test]
    fn v5_errors_use_dedicated_range() {
        assert_eq!(u32::from(V5Error::InvalidWireFormat), 7_000);
        assert_eq!(u32::from(V5Error::ParamModificationNotAnImprovement), 7_009);
        assert_eq!(u32::from(V5Error::FillPayerRemainderNotRentExempt), 7_016);
    }

    #[test]
    fn adapter_discriminator_matches_gateway_abi() {
        assert_eq!(gateway_adapter_discriminator(), crate::instruction::AdapterExecuteAcrossV5::DISCRIMINATOR,);
    }

    #[test]
    fn v1_wire_and_gateway_dispatch_match_golden_fixture() {
        let fixture = fixture();
        let input_bytes = bytes(&fixture, "/wire/depositInput");
        let jit_bytes = bytes(&fixture, "/wire/depositJit");
        let input = decode_v5_adapter_input(&input_bytes).unwrap();
        assert_eq!(serialize(&input), input_bytes);

        let deposit = match &input.mode {
            V5AdapterMode::Deposit(deposit) => deposit,
            _ => panic!("golden mode must be Deposit"),
        };
        assert_eq!(deposit.deposit_params.deposit_nonce, 72_623_859_790_382_856);
        assert!(matches!(deposit.input_amount_mode, V5InputAmountMode::InputVaultBalance { bips: 9_750 }));
        assert_eq!(deposit.modification_rules.authority, array(&fixture, "/jit/authority"));

        let jit = decode_v5_deposit_jit(deposit, &jit_bytes)
            .unwrap()
            .expect("golden JIT must be Deposit");
        assert_eq!(serialize(&jit), jit_bytes);

        let ctx = V5GatewayContext {
            step_id: array(&fixture, "/context/stepId"),
            path_id: array(&fixture, "/context/pathId"),
            submitter: Pubkey::new_from_array(array(&fixture, "/context/submitter")),
        };
        assert_eq!(serialize(&ctx), bytes(&fixture, "/context/borsh"));

        // Local mirror of Gateway `encode_dispatch_data`: discriminator || context || two Borsh byte vectors.
        let mut dispatch = gateway_adapter_discriminator().to_vec();
        dispatch.extend(serialize(&ctx));
        dispatch.extend((input_bytes.len() as u32).to_le_bytes());
        dispatch.extend(&input_bytes);
        dispatch.extend((jit_bytes.len() as u32).to_le_bytes());
        dispatch.extend(&jit_bytes);
        assert_eq!(dispatch, bytes(&fixture, "/dispatch/data"));
    }

    #[test]
    fn evm_hashes_signature_and_domain_separation_match_golden_fixture() {
        let fixture = fixture();
        let gateway = Pubkey::from_str(fixture.pointer("/programs/gateway").unwrap().as_str().unwrap()).unwrap();
        let submitter = Pubkey::new_from_array(array(&fixture, "/context/submitter"));
        let depositor = Pubkey::new_from_array(array(&fixture, "/deposit/depositor"));
        let path_id = array(&fixture, "/context/pathId");
        let nonce = fixture
            .pointer("/deposit/depositNonce")
            .unwrap()
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(
            derive_v5_deposit_id(&gateway, &submitter, &path_id, &depositor, nonce),
            array(&fixture, "/deposit/depositId")
        );

        assert_eq!(v5_param_modification_domain(&gateway), array(&fixture, "/jit/domain"));
        let digest = v5_param_modification_digest(
            &gateway,
            &path_id,
            nonce,
            &array(&fixture, "/jit/newOutputAmount"),
            &Pubkey::new_from_array(array(&fixture, "/jit/newExclusiveRelayer")),
        );
        assert_eq!(digest, array(&fixture, "/jit/digest"));

        let authority = array(&fixture, "/jit/authority");
        let signature = array(&fixture, "/jit/signature");
        verify_v5_authority(&authority, &digest, &signature).unwrap();

        let mut other_path_id = path_id;
        other_path_id[0] ^= 1;
        let other_path_digest = v5_param_modification_digest(
            &gateway,
            &other_path_id,
            nonce,
            &array(&fixture, "/jit/newOutputAmount"),
            &Pubkey::new_from_array(array(&fixture, "/jit/newExclusiveRelayer")),
        );
        assert!(verify_v5_authority(&authority, &other_path_digest, &signature).is_err());

        let other_nonce_digest = v5_param_modification_digest(
            &gateway,
            &path_id,
            nonce + 1,
            &array(&fixture, "/jit/newOutputAmount"),
            &Pubkey::new_from_array(array(&fixture, "/jit/newExclusiveRelayer")),
        );
        assert!(verify_v5_authority(&authority, &other_nonce_digest, &signature).is_err());

        let mut other_authority = authority;
        other_authority[0] ^= 1;
        assert!(verify_v5_authority(&other_authority, &digest, &signature).is_err());

        assert!(recover_v5_authority(&digest, &array(&fixture, "/jit/highSSignature")).is_err());
        let mut invalid_v = signature;
        invalid_v[64] = 0;
        assert!(recover_v5_authority(&digest, &invalid_v).is_err());
    }

    #[test]
    fn pda_domains_match_golden_fixture() {
        let fixture = fixture();
        let submitter = Pubkey::new_from_array(array(&fixture, "/context/submitter"));
        let relay_hash = array(&fixture, "/deposit/depositId");
        let cases = [
            (derive_gateway_dispatch_authority(), "/pdas/dispatchAuthority"),
            (derive_gateway_vault_authority(), "/pdas/gatewayVaultAuthority"),
            (derive_v5_source_delegate(), "/pdas/sourceDelegate"),
            (derive_v5_fill_delegate(), "/pdas/fillDelegate"),
            (derive_v5_fill_payer(&submitter), "/pdas/fillPayer"),
            (derive_fill_status(&relay_hash), "/pdas/fillStatus"),
        ];
        for ((key, bump), path) in cases {
            assert_eq!(key.to_string(), fixture.pointer(&format!("{path}/address")).unwrap().as_str().unwrap());
            assert_eq!(u64::from(bump), fixture.pointer(&format!("{path}/bump")).unwrap().as_u64().unwrap());
        }
    }

    #[test]
    fn decoding_is_strict_and_zero_authority_disables_jit() {
        let fixture = fixture();
        let mut encoded = bytes(&fixture, "/wire/depositInput");
        encoded.push(0);
        assert!(decode_v5_adapter_input(&encoded).is_err());

        let mut wrong_version = bytes(&fixture, "/wire/depositInput");
        wrong_version[0] = V5_ADAPTER_WIRE_VERSION + 1;
        assert_error_name(decode_v5_adapter_input(&wrong_version), "UnsupportedVersion");
        assert_error_name(decode_v5_adapter_input(&[V5_ADAPTER_WIRE_VERSION + 1]), "UnsupportedVersion");
        assert_error_name(decode_v5_adapter_input(&[]), "InvalidWireFormat");

        let mut input = decode_v5_adapter_input(&bytes(&fixture, "/wire/depositInput")).unwrap();
        let deposit = match &mut input.mode {
            V5AdapterMode::Deposit(deposit) => deposit,
            _ => unreachable!(),
        };
        deposit.modification_rules = V5DepositModificationRules {
            authority: [0u8; 20],
            allow_output_amount: false,
            allow_exclusive_relayer: false,
        };
        let input = decode_v5_adapter_input(&serialize(&input)).unwrap();
        let deposit = match &input.mode {
            V5AdapterMode::Deposit(deposit) => deposit,
            _ => unreachable!(),
        };
        assert!(decode_v5_deposit_jit(deposit, &[]).unwrap().is_none());
        assert!(decode_v5_deposit_jit(deposit, &[0]).is_err());

        let mut invalid_rules = input;
        if let V5AdapterMode::Deposit(deposit) = &mut invalid_rules.mode {
            deposit.modification_rules.allow_output_amount = true;
        }
        assert!(decode_v5_adapter_input(&serialize(&invalid_rules)).is_err());
    }

    #[test]
    fn fill_wire_is_branch_specific() {
        let fixture = fixture();
        let input = decode_v5_adapter_input(&bytes(&fixture, "/wire/fillInput")).unwrap();
        assert!(matches!(input.mode, V5AdapterMode::Fill(_)));
        decode_v5_fill_jit(&bytes(&fixture, "/wire/fillJit")).unwrap();
        assert!(decode_v5_fill_jit(&bytes(&fixture, "/wire/depositJit")).is_err());
    }

    #[test]
    fn balance_resolution_floor_and_ordinary_delegate_allowance_are_strict() {
        assert_eq!(resolve_v5_input_amount(V5InputAmountMode::Literal, 99, 0).unwrap(), 99);
        assert_eq!(resolve_v5_input_amount(V5InputAmountMode::InputVaultBalance { bips: 9_750 }, 97, 101).unwrap(), 98);
        assert!(resolve_v5_input_amount(V5InputAmountMode::InputVaultBalance { bips: 9_750 }, 99, 101).is_err());
        assert!(resolve_v5_input_amount(
            V5InputAmountMode::InputVaultBalance { bips: BIPS_DENOMINATOR + 1 },
            0,
            u64::MAX
        )
        .is_err());

        require_v5_delegate_allowance(99, 99).unwrap();
        require_v5_delegate_allowance(u64::MAX, 99).unwrap();
        assert!(require_v5_delegate_allowance(98, 99).is_err());
    }

    #[test]
    fn jit_permissions_and_improvement_rule_match_evm_behavior() {
        let fixture = fixture();
        let input = decode_v5_adapter_input(&bytes(&fixture, "/wire/depositInput")).unwrap();
        let mut deposit = match input.mode {
            V5AdapterMode::Deposit(deposit) => deposit,
            _ => unreachable!(),
        };
        let jit: AcrossDepositJitParams = decode_strict(&bytes(&fixture, "/wire/depositJit")).unwrap();
        let gateway = Pubkey::from_str(fixture.pointer("/programs/gateway").unwrap().as_str().unwrap()).unwrap();
        let path_id = array(&fixture, "/context/pathId");

        assert_eq!(
            resolve_v5_deposit_modifications(&deposit, &jit, &gateway, &path_id).unwrap(),
            (jit.new_output_amount, jit.new_exclusive_relayer)
        );

        deposit.modification_rules.allow_exclusive_relayer = false;
        assert_eq!(
            resolve_v5_deposit_modifications(&deposit, &jit, &gateway, &path_id)
                .unwrap()
                .1,
            deposit.deposit_params.exclusive_relayer
        );

        let mut worse = jit;
        worse.new_output_amount = [0u8; 32];
        let digest = v5_param_modification_digest(
            &gateway,
            &path_id,
            deposit.deposit_params.deposit_nonce,
            &worse.new_output_amount,
            &worse.new_exclusive_relayer,
        );
        let secret_bytes: [u8; 32] = hex::decode("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
            .try_into()
            .unwrap();
        let secret = libsecp256k1::SecretKey::parse(&secret_bytes).unwrap();
        let (signature, recovery_id) = libsecp256k1::sign(&libsecp256k1::Message::parse(&digest), &secret);
        worse.signature[..64].copy_from_slice(&signature.serialize());
        worse.signature[64] = recovery_id.serialize() + 27;
        assert!(resolve_v5_deposit_modifications(&deposit, &worse, &gateway, &path_id).is_err());
    }
}
