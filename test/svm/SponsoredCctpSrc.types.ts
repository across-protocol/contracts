import { ethers } from "ethers";
import type { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";

export interface SponsoredCCTPQuote {
  sourceDomain: number; // uint32
  destinationDomain: number; // uint32
  mintRecipient: string; // bytes32
  amount: ethers.BigNumberish; // uint256
  burnToken: string; // bytes32
  destinationCaller: string; // bytes32
  maxFee: ethers.BigNumberish; // uint256
  minFinalityThreshold: number; // uint32
  nonce: string; // bytes32
  deadline: ethers.BigNumberish; // uint256
  maxBpsToSponsor: ethers.BigNumberish; // uint256
  maxUserSlippageBps: ethers.BigNumberish; // uint256
  finalRecipient: string; // bytes32
  finalToken: string; // bytes32
  executionMode: number; // uint8
  actionData: ethers.BytesLike; // bytes
}

export interface SponsoredCCTPQuoteSVM {
  sourceDomain: number; // u32
  destinationDomain: number; // u32
  mintRecipient: PublicKey; // Pubkey
  amount: BN; // u64
  burnToken: PublicKey; // Pubkey
  destinationCaller: PublicKey; // Pubkey
  maxFee: BN; // u64
  minFinalityThreshold: number; // u32
  nonce: number[]; // [u8; 32]
  deadline: BN; // u64
  maxBpsToSponsor: BN; // u64
  maxUserSlippageBps: BN; // u64
  finalRecipient: PublicKey; // Pubkey
  finalToken: PublicKey; // Pubkey
  executionMode: number; // u8
  actionData: Buffer; // Vec<u8>
}

export interface HookData {
  nonce: string; // bytes32
  deadline: ethers.BigNumber; // uint256
  maxBpsToSponsor: ethers.BigNumber; // uint256
  maxUserSlippageBps: ethers.BigNumber; // uint256
  finalRecipient: string; // bytes32
  finalToken: string; // bytes32
  executionMode: number; // uint8
  actionData: string; // bytes
}
