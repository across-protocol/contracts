import { BN } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import { RelayData } from "../../../src/types/svm";

// Deterministic test keys, not production credentials. The matching fill-status account is loaded at genesis.
export const legacyMint = Keypair.fromSeed(Buffer.alloc(32, 221));
export const legacyRequester = Keypair.fromSeed(Buffer.alloc(32, 222)).publicKey;
export const legacyRelay: RelayData = {
  depositor: legacyRequester,
  recipient: Keypair.fromSeed(Buffer.alloc(32, 223)).publicKey,
  exclusiveRelayer: PublicKey.default,
  inputToken: legacyMint.publicKey,
  outputToken: legacyMint.publicKey,
  inputAmount: [...Buffer.alloc(31), 1],
  outputAmount: new BN(500000),
  originChainId: new BN(1),
  depositId: [...Buffer.alloc(31), 221],
  fillDeadline: 4000000000,
  exclusivityDeadline: 0,
  message: Buffer.alloc(0),
};
