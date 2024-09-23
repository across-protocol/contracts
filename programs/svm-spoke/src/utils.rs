use crate::error::CustomError;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak;
use std::mem::size_of_val;

use crate::{
    constants::DISCRIMINATOR_SIZE, error::CalldataError, instructions::V3RelayData,
    program::SvmSpoke,
};

pub trait EncodeInstructionData {
    fn encode_instruction_data(&self, discriminator_str: &str) -> Result<Vec<u8>>;
}

impl<T: AnchorSerialize> EncodeInstructionData for T {
    fn encode_instruction_data(&self, discriminator_str: &str) -> Result<Vec<u8>> {
        let mut data = Vec::with_capacity(DISCRIMINATOR_SIZE + size_of_val(self));
        data.extend_from_slice(
            &anchor_lang::solana_program::hash::hash(discriminator_str.as_bytes()).to_bytes()
                [..DISCRIMINATOR_SIZE],
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
    let slice = data.get(..4).ok_or(CalldataError::InvalidSelector)?;
    let array = <[u8; 4]>::try_from(slice).unwrap();
    Ok(array)
}

pub fn get_solidity_arg(data: &Vec<u8>, index: usize) -> Result<[u8; 32]> {
    let offset = 4 + 32 * index;
    let slice = data
        .get(offset..offset + 32)
        .ok_or(CalldataError::InvalidArgument)?;
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
            _ => return Err(CalldataError::InvalidBool.into()),
        },
        _ => return Err(CalldataError::InvalidBool.into()),
    }
}

pub fn get_self_authority_pda() -> Pubkey {
    let (pda_address, _bump) = Pubkey::find_program_address(&[b"self_authority"], &SvmSpoke::id());
    pda_address
}

pub fn decode_solidity_uint64(data: &[u8; 32]) -> Result<u64> {
    let h_value = u128::from_be_bytes(data[..16].try_into().unwrap());
    let l_value = u128::from_be_bytes(data[16..].try_into().unwrap());
    if h_value > 0 || l_value > u64::MAX as u128 {
        return Err(CalldataError::InvalidUint64.into());
    }
    Ok(l_value as u64)
}

pub fn decode_solidity_address(data: &[u8; 32]) -> Result<Pubkey> {
    for i in 0..12 {
        if data[i] != 0 {
            return Err(CalldataError::InvalidAddress.into());
        }
    }
    Ok(Pubkey::new_from_array(*data))
}

// Across specific utilities.
pub fn get_v3_relay_hash(relay_data: &V3RelayData, chain_id: u64) -> [u8; 32] {
    let mut input = relay_data.try_to_vec().unwrap();
    input.extend_from_slice(&chain_id.to_le_bytes());
    // Log the input that will be hashed
    msg!("Input to be hashed: {:?}", input);
    keccak::hash(&input).0
}

pub fn verify_merkle_proof(root: [u8; 32], leaf: [u8; 32], proof: Vec<[u8; 32]>) -> Result<()> {
    msg!("Verifying merkle proof");
    let computed_root = process_proof(&proof, &leaf);
    if computed_root != root {
        msg!("Invalid proof: computed root does not match provided root");
        return Err(CustomError::InvalidProof.into());
    }
    msg!("Merkle proof verified successfully");
    Ok(())
}

// The following is the rust implementation of the merkle proof verification from OpenZeppelin that can be found here:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/MerkleProof.sol
pub fn process_proof(proof: &[[u8; 32]], leaf: &[u8; 32]) -> [u8; 32] {
    let mut computed_hash = *leaf;
    for proof_element in proof.iter() {
        computed_hash = commutative_keccak256(&computed_hash, proof_element);
    }
    computed_hash
}

// See https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/Hashes.sol
fn commutative_keccak256(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    if a < b {
        efficient_keccak256(a, b)
    } else {
        efficient_keccak256(b, a)
    }
}

fn efficient_keccak256(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let mut input = [0u8; 64];
    input[..32].copy_from_slice(a);
    input[32..].copy_from_slice(b);
    keccak::hash(&input).0
}

//TODO: we might want to split this utils up into different files. we have a) CCTP b) Merkle proof c) Bitmap sections. At minimum we should have more comments splitting these up.

pub fn is_claimed(claimed_bitmap: &Vec<u8>, index: u32) -> bool {
    let byte_index = (index / 8) as usize; // Index of the byte in the array
    if byte_index >= claimed_bitmap.len() {
        return false; // Out of bounds, treat as not claimed
    }
    let bit_in_byte_index = (index % 8) as usize; // Index of the bit within the byte
    let claimed_byte = claimed_bitmap[byte_index];
    let mask = 1 << bit_in_byte_index;
    claimed_byte & mask == mask
}

pub fn set_claimed(claimed_bitmap: &mut Vec<u8>, index: u32) {
    let byte_index = (index / 8) as usize; // Index of the byte in the array
    if byte_index >= claimed_bitmap.len() {
        let new_size = byte_index + 1;
        claimed_bitmap.resize(new_size, 0); // Resize the Vec if necessary
    }
    let bit_in_byte_index = (index % 8) as usize; // Index of the bit within the byte
    claimed_bitmap[byte_index] |= 1 << bit_in_byte_index;
}
