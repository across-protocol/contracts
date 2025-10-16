import { ethers } from "ethers";

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
  finalRecipient: string; // bytes32
  finalToken: string; // bytes32
}
