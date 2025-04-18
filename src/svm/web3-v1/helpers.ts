import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { BigNumber } from "@ethersproject/bignumber";
import { ethers } from "ethers";
import { DepositData } from "../../types/svm";
import { PublicKey } from "@solana/web3.js";
import { serialize } from "borsh";

/**
 * Returns the chainId for a given solana cluster.
 */
export const getSolanaChainId = (cluster: "devnet" | "mainnet"): BigNumber => {
  return BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${cluster}`))) & BigInt("0xFFFFFFFFFFFF")
  );
};

/**
 * Returns true if the provider is on the devnet cluster.
 */
export const isSolanaDevnet = (provider: AnchorProvider): boolean => {
  const solanaRpcEndpoint = provider.connection.rpcEndpoint;
  if (solanaRpcEndpoint.includes("devnet")) return true;
  else if (solanaRpcEndpoint.includes("mainnet")) return false;
  else throw new Error(`Unsupported solanaCluster endpoint: ${solanaRpcEndpoint}`);
};

/**
 * Borsh‐serializable struct matching your Rust DelegateSeedData
 */
class DelegateSeedData {
  depositor!: Uint8Array;
  recipient!: Uint8Array;
  inputToken!: Uint8Array;
  outputToken!: Uint8Array;
  inputAmount!: BN;
  outputAmount!: BN;
  destinationChainId!: BN;
  exclusiveRelayer!: Uint8Array;
  quoteTimestamp!: BN;
  fillDeadline!: BN;
  exclusivityParameter!: BN;
  message!: Uint8Array;

  constructor(fields: {
    depositor: Uint8Array;
    recipient: Uint8Array;
    inputToken: Uint8Array;
    outputToken: Uint8Array;
    inputAmount: BN;
    outputAmount: BN;
    destinationChainId: BN;
    exclusiveRelayer: Uint8Array;
    quoteTimestamp: BN;
    fillDeadline: BN;
    exclusivityParameter: BN;
    message: Uint8Array;
  }) {
    Object.assign(this, fields);
  }
}

/**
 * Borsh schema for DelegateSeedData
 */
const delegateSeedSchema = new Map([
  [
    DelegateSeedData,
    {
      kind: "struct",
      fields: [
        ["depositor", [32]],
        ["recipient", [32]],
        ["inputToken", [32]],
        ["outputToken", [32]],
        ["inputAmount", "u64"],
        ["outputAmount", "u64"],
        ["destinationChainId", "u64"],
        ["exclusiveRelayer", [32]],
        ["quoteTimestamp", "u32"],
        ["fillDeadline", "u32"],
        ["exclusivityParameter", "u32"],
        ["message", ["u8"]],
      ],
    },
  ],
]);

export function getDepositDelegateSeedHash(depositData: DepositData): Uint8Array {
  // Build the JS object that matches DelegateSeedData
  const ds = new DelegateSeedData({
    depositor: depositData.depositor!.toBuffer(),
    recipient: depositData.recipient.toBuffer(),
    inputToken: depositData.inputToken!.toBuffer(),
    outputToken: depositData.outputToken.toBuffer(),
    inputAmount: depositData.inputAmount,
    outputAmount: depositData.outputAmount,
    destinationChainId: depositData.destinationChainId,
    exclusiveRelayer: depositData.exclusiveRelayer.toBuffer(),
    quoteTimestamp: depositData.quoteTimestamp,
    fillDeadline: depositData.fillDeadline,
    exclusivityParameter: depositData.exclusivityParameter,
    // Borsh will automatically prefix this with a 4‑byte LE length
    message: Uint8Array.from(depositData.message),
  });

  // Serialize with borsh
  const serialized = serialize(delegateSeedSchema, ds); // Uint8Array
  const hashHex = ethers.utils.keccak256(serialized);
  const seedHash = Buffer.from(hashHex.slice(2), "hex");
  return seedHash;
}

/**
 * Returns the delegate PDA for a deposit, Borsh‐serializing exactly the same fields
 * and ordering as your Rust `derive_delegate_seed_hash`.
 */
export function getDepositDelegatePda(depositData: DepositData, programId: PublicKey): PublicKey {
  const seedHash = getDepositDelegateSeedHash(depositData);

  // Derive PDA with seeds ["delegate", seedHash]
  const [pda] = PublicKey.findProgramAddressSync([Buffer.from("delegate"), seedHash], programId);

  return pda;
}

/**
 * Returns the delegate PDA for a fill relay.
 */
export const getFillRelayDelegatePda = (relayHash: Uint8Array, stateSeed: BN, programId: PublicKey) => {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("delegate"), stateSeed.toArrayLike(Buffer, "le", 8), relayHash],
    programId
  )[0];
};
