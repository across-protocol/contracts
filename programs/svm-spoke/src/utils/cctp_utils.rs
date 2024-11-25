use anchor_lang::prelude::*;
use std::mem::size_of_val;

use crate::{constants::DISCRIMINATOR_SIZE, error::CallDataError, program::SvmSpoke};

pub trait EncodeInstructionData {
    fn encode_instruction_data(&self, discriminator_str: &str) -> Result<Vec<u8>>;
}

impl<T: AnchorSerialize> EncodeInstructionData for T {
    fn encode_instruction_data(&self, discriminator_str: &str) -> Result<Vec<u8>> {
        let mut data = Vec::with_capacity(DISCRIMINATOR_SIZE + size_of_val(self));
        data.extend_from_slice(
            &anchor_lang::solana_program::hash::hash(discriminator_str.as_bytes()).to_bytes()[..DISCRIMINATOR_SIZE],
        );
        data.extend_from_slice(&self.try_to_vec()?);

        Ok(data)
    }
}

pub fn encode_solidity_selector(signature: &str) -> [u8; 4] {
    let hash = anchor_lang::solana_program::keccak::hash(signature.as_bytes());
    let mut selector = [0u8; 4];
    selector.copy_from_slice(&hash.to_bytes()[..4]);
    selector
}

pub fn get_solidity_selector(data: &Vec<u8>) -> Result<[u8; 4]> {
    let slice = data.get(..4).ok_or(CallDataError::InvalidSelector)?;
    let array = <[u8; 4]>::try_from(slice).unwrap();
    Ok(array)
}

pub fn get_solidity_arg(data: &Vec<u8>, index: usize) -> Result<[u8; 32]> {
    let offset = 4 + 32 * index;
    let slice = data.get(offset..offset + 32).ok_or(CallDataError::InvalidArgument)?;
    let array = <[u8; 32]>::try_from(slice).unwrap();
    Ok(array)
}

pub fn decode_solidity_bool(data: &[u8; 32]) -> Result<bool> {
    let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
    let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
    match h_value {
        0 => match l_value {
            0 => Ok(false),
            1 => Ok(true),
            _ => {
                err!(CallDataError::InvalidBool)
            }
        },
        _ => {
            err!(CallDataError::InvalidBool)
        }
    }
}

pub fn get_self_authority_pda() -> Pubkey {
    let (pda_address, _bump) = Pubkey::find_program_address(&[b"self_authority"], &SvmSpoke::id());
    pda_address
}

pub fn decode_solidity_uint32(data: &[u8; 32]) -> Result<u32> {
    let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
    let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
    if h_value > 0 || l_value > (u32::MAX as u128) {
        return err!(CallDataError::InvalidUint32);
    }
    Ok(l_value as u32)
}

pub fn decode_solidity_uint64(data: &[u8; 32]) -> Result<u64> {
    let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
    let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
    if h_value > 0 || l_value > (u64::MAX as u128) {
        return err!(CallDataError::InvalidUint64);
    }
    Ok(l_value as u64)
}

pub fn decode_solidity_address(data: &[u8; 32]) -> Result<Pubkey> {
    for i in 0..12 {
        if data[i] != 0 {
            return err!(CallDataError::InvalidAddress);
        }
    }
    Ok(Pubkey::new_from_array(*data))
}
