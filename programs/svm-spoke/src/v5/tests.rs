use anchor_lang::{prelude::*, solana_program::keccak, Discriminator};

use super::{codec::*, jit::*, pda::*};
use crate::{
    constants::{
        BIPS_DENOMINATOR, GATEWAY_ADAPTER_EXECUTE_V5_DISCRIMINATOR, GATEWAY_DISPATCH_AUTHORITY,
        GATEWAY_DISPATCH_AUTHORITY_BUMP, GATEWAY_DISPATCH_AUTHORITY_SEED, GATEWAY_PROGRAM_ID, GATEWAY_VAULT_AUTHORITY,
        GATEWAY_VAULT_AUTHORITY_BUMP, GATEWAY_VAULT_AUTHORITY_SEED, V5_FILL_DELEGATE, V5_FILL_DELEGATE_BUMP,
        V5_FILL_DELEGATE_SEED, V5_SOURCE_DELEGATE, V5_SOURCE_DELEGATE_BUMP, V5_SOURCE_DELEGATE_SEED,
    },
    ID,
};
use serde_json::Value;
use std::str::FromStr;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../fixtures/v5_adapter_v1.json")).unwrap()
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
fn adapter_discriminator_matches_gateway_abi() {
    assert_eq!(GATEWAY_ADAPTER_EXECUTE_V5_DISCRIMINATOR, crate::instruction::AdapterExecuteAcrossV5::DISCRIMINATOR,);
}

#[test]
fn gateway_path_root_and_witness_match_cross_vm_fixture() {
    let fixture: Value = serde_json::from_str(include_str!("../../fixtures/v5_gateway_path.json")).unwrap();
    let mut chain_word = [0u8; 32];
    chain_word[24..].copy_from_slice(&fixture["chainId"].as_u64().unwrap().to_be_bytes());
    let message_hash = keccak::hash(&bytes(&fixture, "/message")).to_bytes();
    let path_hash = |salt: &str| {
        keccak::hashv(&[
            &chain_word,
            &bytes(&fixture, salt),
            &bytes(&fixture, "/executor"),
            &message_hash,
        ])
        .to_bytes()
    };
    let a = path_hash("/salt");
    let b = path_hash("/siblingSalt");
    assert_eq!(a, array::<32>(&fixture, "/pathId"));
    assert_eq!(b, array::<32>(&fixture, "/siblingPathId"));
    let pair = |a: [u8; 32], b: [u8; 32]| {
        if a < b {
            keccak::hashv(&[&a, &b])
        } else {
            keccak::hashv(&[&b, &a])
        }
        .to_bytes()
    };
    let root = pair(a, b);
    assert_eq!(root, array::<32>(&fixture, "/stepRoot"));
    assert_eq!(pair(b, a), root);
    assert_eq!([crate::constants::V5_MAGIC_PREFIX.as_slice(), &root].concat(), bytes(&fixture, "/witness"));
}

#[test]
fn v1_wire_and_gateway_dispatch_match_golden_fixture() {
    let fixture = fixture();
    assert_eq!(
        GATEWAY_ADAPTER_EXECUTE_V5_DISCRIMINATOR,
        anchor_lang::solana_program::hash::hash(b"global:adapter_execute_across_v5").to_bytes()[..8]
    );
    let input_bytes = bytes(&fixture, "/wire/depositInput");
    let jit_bytes = bytes(&fixture, "/wire/depositJit");
    let input = decode_v5_adapter_input(&input_bytes).unwrap();
    assert_eq!(serialize(&input), input_bytes);

    let deposit = match &input {
        V5AdapterInput::DepositV1(deposit) => deposit,
        _ => panic!("golden mode must be Deposit"),
    };
    assert_eq!(deposit.deposit_params.deposit_nonce, 72_623_859_790_382_856);
    assert!(matches!(deposit.input_amount_mode, V5InputAmountMode::InputVaultBalance { bips: 9_750 }));
    assert_eq!(deposit.modification_rules.authority, array(&fixture, "/jit/authority"));

    let jit: AcrossDepositJitParams = decode_strict(&jit_bytes).unwrap();
    assert_eq!(serialize(&jit), jit_bytes);

    let ctx = GatewayContextV1 {
        step_id: array(&fixture, "/context/stepId"),
        path_id: array(&fixture, "/context/pathId"),
        submitter: Pubkey::new_from_array(array(&fixture, "/context/submitter")),
    };
    assert_eq!(serialize(&ctx), bytes(&fixture, "/context/borsh"));

    // Local mirror of Gateway `encode_dispatch_data`: discriminator || context || two Borsh byte vectors.
    let mut dispatch = GATEWAY_ADAPTER_EXECUTE_V5_DISCRIMINATOR.to_vec();
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

    assert_eq!(keccak::hash(V5_PARAM_MODIFICATION_NAME).to_bytes(), V5_PARAM_MODIFICATION_NAME_HASH);
    assert_eq!(V5_PARAM_MODIFICATION_NAME_HASH, array(&fixture, "/jit/nameHash"));
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
    assert_error_name(verify_v5_authority(&[0u8; 20], &digest, &signature), "InvalidParamModificationSignature");

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
        ((GATEWAY_DISPATCH_AUTHORITY, GATEWAY_DISPATCH_AUTHORITY_BUMP), "/pdas/dispatchAuthority"),
        ((GATEWAY_VAULT_AUTHORITY, GATEWAY_VAULT_AUTHORITY_BUMP), "/pdas/gatewayVaultAuthority"),
        ((V5_SOURCE_DELEGATE, V5_SOURCE_DELEGATE_BUMP), "/pdas/sourceDelegate"),
        ((V5_FILL_DELEGATE, V5_FILL_DELEGATE_BUMP), "/pdas/fillDelegate"),
        (derive_v5_fill_payer(&submitter), "/pdas/fillPayer"),
        (derive_fill_status(&relay_hash), "/pdas/fillStatus"),
    ];
    for ((key, bump), path) in cases {
        assert_eq!(key.to_string(), fixture.pointer(&format!("{path}/address")).unwrap().as_str().unwrap());
        assert_eq!(u64::from(bump), fixture.pointer(&format!("{path}/bump")).unwrap().as_u64().unwrap());
    }
}

#[test]
fn hardcoded_v5_authorities_match_canonical_pdas() {
    assert_eq!(
        Pubkey::find_program_address(&[GATEWAY_DISPATCH_AUTHORITY_SEED, ID.as_ref()], &GATEWAY_PROGRAM_ID),
        (GATEWAY_DISPATCH_AUTHORITY, GATEWAY_DISPATCH_AUTHORITY_BUMP)
    );
    assert_eq!(
        Pubkey::find_program_address(&[GATEWAY_VAULT_AUTHORITY_SEED], &GATEWAY_PROGRAM_ID),
        (GATEWAY_VAULT_AUTHORITY, GATEWAY_VAULT_AUTHORITY_BUMP)
    );
    assert_eq!(
        Pubkey::find_program_address(&[V5_SOURCE_DELEGATE_SEED], &ID),
        (V5_SOURCE_DELEGATE, V5_SOURCE_DELEGATE_BUMP)
    );
    assert_eq!(Pubkey::find_program_address(&[V5_FILL_DELEGATE_SEED], &ID), (V5_FILL_DELEGATE, V5_FILL_DELEGATE_BUMP));
}

#[test]
fn strict_decoding_and_jit_gating_are_explicit() {
    let fixture = fixture();
    let mut encoded = bytes(&fixture, "/wire/depositInput");
    encoded.push(0);
    assert!(decode_v5_adapter_input(&encoded).is_err());

    assert_error_name(decode_v5_adapter_input(&[2]), "InvalidWireFormat");
    assert_error_name(decode_v5_adapter_input(&[]), "InvalidWireFormat");

    let mut input = decode_v5_adapter_input(&bytes(&fixture, "/wire/depositInput")).unwrap();
    let deposit = match &mut input {
        V5AdapterInput::DepositV1(deposit) => deposit,
        _ => unreachable!(),
    };
    deposit.modification_rules =
        V5DepositModificationRules { authority: [0u8; 20], allow_output_amount: false, allow_exclusive_relayer: false };
    let input = decode_v5_adapter_input(&serialize(&input)).unwrap();
    let deposit = match &input {
        V5AdapterInput::DepositV1(deposit) => deposit,
        _ => unreachable!(),
    };
    assert!(!deposit.modification_rules.requires_jit());

    let mut permissionless_rules = input;
    if let V5AdapterInput::DepositV1(deposit) = &mut permissionless_rules {
        deposit.modification_rules.allow_output_amount = true;
    }
    let permissionless_rules = decode_v5_adapter_input(&serialize(&permissionless_rules)).unwrap();
    let deposit = match &permissionless_rules {
        V5AdapterInput::DepositV1(deposit) => deposit,
        _ => unreachable!(),
    };
    assert!(deposit.modification_rules.requires_jit());
    assert!(decode_strict::<AcrossDepositJitParams>(&[]).is_err());
}

#[test]
fn fill_wire_is_branch_specific() {
    let fixture = fixture();
    let input_bytes = bytes(&fixture, "/wire/fillInput");
    let input = decode_v5_adapter_input(&input_bytes).unwrap();
    assert!(matches!(input, V5AdapterInput::FillV1(_)));
    assert_eq!(serialize(&input), input_bytes);
    decode_strict::<V5FillJit>(&bytes(&fixture, "/wire/fillJit")).unwrap();
    assert!(decode_strict::<V5FillJit>(&bytes(&fixture, "/wire/depositJit")).is_err());
}

#[test]
fn balance_resolution_floor_is_strict() {
    let fixture = fixture();
    let mut input = decode_v5_adapter_input(&bytes(&fixture, "/wire/depositInput")).unwrap();
    if let V5AdapterInput::DepositV1(deposit) = &mut input {
        deposit.input_amount_mode = V5InputAmountMode::InputVaultBalance { bips: BIPS_DENOMINATOR + 1 };
    }
    decode_v5_adapter_input(&serialize(&input)).unwrap();

    assert_eq!(resolve_v5_input_amount(V5InputAmountMode::Literal, 99, 0).unwrap(), 99);
    assert_eq!(resolve_v5_input_amount(V5InputAmountMode::InputVaultBalance { bips: 9_750 }, 97, 101).unwrap(), 98);
    assert!(resolve_v5_input_amount(V5InputAmountMode::InputVaultBalance { bips: 9_750 }, 99, 101).is_err());
    assert_error_name(
        resolve_v5_input_amount(V5InputAmountMode::InputVaultBalance { bips: BIPS_DENOMINATOR + 1 }, 0, u64::MAX),
        "InvalidAmountBips",
    );
}

#[test]
fn jit_permissions_and_improvement_rule_match_evm_behavior() {
    let fixture = fixture();
    let input = decode_v5_adapter_input(&bytes(&fixture, "/wire/depositInput")).unwrap();
    let mut deposit = match input {
        V5AdapterInput::DepositV1(deposit) => deposit,
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

    let mut worse = jit.clone();
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

    deposit.modification_rules.allow_output_amount = false;
    assert_eq!(
        resolve_v5_deposit_modifications(&deposit, &jit, &gateway, &path_id).unwrap(),
        (deposit.deposit_params.output_amount, deposit.deposit_params.exclusive_relayer)
    );

    deposit.modification_rules.authority = [0u8; 20];
    deposit.modification_rules.allow_output_amount = true;
    let mut unsigned_jit = jit;
    unsigned_jit.signature = [0u8; V5_SIGNATURE_LEN];
    assert_eq!(
        resolve_v5_deposit_modifications(&deposit, &unsigned_jit, &gateway, &path_id).unwrap(),
        (unsigned_jit.new_output_amount, deposit.deposit_params.exclusive_relayer)
    );

    deposit.modification_rules.allow_output_amount = false;
    deposit.modification_rules.allow_exclusive_relayer = true;
    assert_eq!(
        resolve_v5_deposit_modifications(&deposit, &unsigned_jit, &gateway, &path_id).unwrap(),
        (deposit.deposit_params.output_amount, unsigned_jit.new_exclusive_relayer)
    );

    deposit.modification_rules.allow_exclusive_relayer = false;
    assert!(!deposit.modification_rules.requires_jit());
    assert_eq!(
        resolve_v5_deposit_modifications(&deposit, &unsigned_jit, &gateway, &path_id).unwrap(),
        (deposit.deposit_params.output_amount, deposit.deposit_params.exclusive_relayer)
    );
}
