use crate::*;
use anchor_lang::{solana_program::program_error::ProgramError, Discriminator, InstructionData};

#[test]
fn retired_slow_fill_discriminators_are_not_dispatchable() {
    for discriminator in [
        [39, 157, 165, 187, 88, 217, 207, 98],
        [26, 207, 3, 168, 193, 252, 59, 127],
    ] {
        // Both historical selectors must fail at dispatch, before deserializing arguments or validating accounts.
        for payload in [vec![], vec![0; 512]] {
            let data = [discriminator.as_slice(), payload.as_slice()].concat();
            assert_eq!(entry(&ID, &[], &data), Err(ProgramError::Custom(101)));
        }
    }
}

#[test]
fn historical_status_and_event_slots_remain_readable() {
    assert_eq!(FillStatusAccount::DISCRIMINATOR, &[105, 89, 88, 35, 24, 147, 178, 137]);
    for (slot, status) in [
        (0, FillStatus::Unfilled),
        (1, FillStatus::RequestedSlowFill),
        (2, FillStatus::Filled),
    ] {
        let mut bytes = vec![105, 89, 88, 35, 24, 147, 178, 137, slot];
        bytes.extend_from_slice(&[42; 32]);
        bytes.extend_from_slice(&4_000_000_000u32.to_le_bytes());
        let decoded = FillStatusAccount::try_deserialize(&mut bytes.as_slice()).unwrap();
        assert!(decoded.status == status);
        assert_eq!(decoded.relayer, Pubkey::new_from_array([42; 32]));
        assert_eq!(decoded.fill_deadline, 4_000_000_000);
        let mut encoded = Vec::new();
        decoded.try_serialize(&mut encoded).unwrap();
        assert_eq!(encoded, bytes);
        assert_eq!(bytes.len(), 8 + FillStatusAccount::INIT_SPACE);
    }

    use crate::event::{FillType, FilledRelay, RequestedSlowFill};
    for (slot, fill_type) in [
        (0, FillType::FastFill),
        (1, FillType::ReplacedSlowFill),
        (2, FillType::SlowFill),
    ] {
        let mut historical_event = vec![0; 393];
        historical_event[392] = slot;
        let decoded = FilledRelay::deserialize(&mut historical_event.as_slice()).unwrap();
        assert!(decoded.relay_execution_info.fill_type == fill_type);
        assert_eq!(decoded.try_to_vec().unwrap(), historical_event);
    }
    assert_eq!(FilledRelay::DISCRIMINATOR, &[25, 58, 182, 0, 50, 99, 160, 117]);
    assert_eq!(RequestedSlowFill::DISCRIMINATOR, &[221, 123, 11, 14, 71, 37, 178, 167]);
    let historical_request = vec![0; 280];
    let decoded = RequestedSlowFill::deserialize(&mut historical_request.as_slice()).unwrap();
    assert_eq!(decoded.try_to_vec().unwrap(), historical_request);
}

#[test]
fn root_bundle_keeps_both_roots_and_admin_payload() {
    let data = instruction::RelayRootBundle { relayer_refund_root: [1; 32], slow_relay_root: [2; 32] }.data();
    assert_eq!(data, [vec![69, 13, 223, 204, 251, 61, 105, 6], vec![1; 32], vec![2; 32]].concat());
    let root = RootBundle { relayer_refund_root: [1; 32], slow_relay_root: [2; 32], claimed_bitmap: vec![5] };
    let mut bytes = Vec::new();
    root.try_serialize(&mut bytes).unwrap();
    assert_eq!(&bytes[8..], &[vec![1; 32], vec![2; 32], vec![1, 0, 0, 0, 5]].concat());
    let decoded = RootBundle::try_deserialize(&mut bytes.as_slice()).unwrap();
    assert_eq!(decoded.slow_relay_root, [2; 32]);
    assert_eq!(decoded.claimed_bitmap, vec![5]);
}
