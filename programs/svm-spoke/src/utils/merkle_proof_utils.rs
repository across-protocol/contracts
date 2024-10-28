use anchor_lang::{ prelude::*, solana_program::keccak };

use crate::{ error::CustomError, instructions::V3RelayData };

pub fn get_v3_relay_hash(relay_data: &V3RelayData, chain_id: u64) -> [u8; 32] {
  let mut input = relay_data.try_to_vec().unwrap();
  input.extend_from_slice(&chain_id.to_le_bytes());
  keccak::hash(&input).0
}

pub fn verify_merkle_proof(root: [u8; 32], leaf: [u8; 32], proof: Vec<[u8; 32]>) -> Result<()> {
  let computed_root = process_proof(&proof, &leaf);
  if computed_root != root {
    return err!(CustomError::InvalidMerkleProof);
  }

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
  if a < b { efficient_keccak256(a, b) } else { efficient_keccak256(b, a) }
}

fn efficient_keccak256(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
  let mut input = [0u8; 64];
  input[..32].copy_from_slice(a);
  input[32..].copy_from_slice(b);
  keccak::hash(&input).0
}
