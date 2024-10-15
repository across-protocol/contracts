import { BN, Program } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import * as crypto from "crypto";
import { SvmSpoke } from "../../target/types/svm_spoke";

import {
  readProgramEvents,
  calculateRelayHashUint8Array,
  findProgramAddress,
  LargeAccountsCoder,
} from "../../src/SvmUtils";

export { readProgramEvents, calculateRelayHashUint8Array, findProgramAddress };

export async function printLogs(connection: any, program: any, tx: any) {
  const latestBlockHash = await connection.getLatestBlockhash();
  await connection.confirmTransaction(
    {
      blockhash: latestBlockHash.blockhash,
      lastValidBlockHeight: latestBlockHash.lastValidBlockHeight,
      signature: tx,
    },
    "confirmed"
  );

  const txDetails = await program.provider.connection.getTransaction(tx, {
    maxSupportedTransactionVersion: 0,
    commitment: "confirmed",
  });

  const logs = txDetails?.meta?.logMessages || null;

  if (!logs) {
    console.log("No logs found");
  }
}

export function randomAddress(): string {
  const wallet = ethers.Wallet.createRandom();
  return wallet.address;
}

export function randomBigInt(bytes = 8, signed = false) {
  const sign = signed && Math.random() < 0.5 ? "-" : "";
  const byteString = "0x" + Buffer.from(crypto.randomBytes(bytes)).toString("hex");
  return BigInt(sign + byteString);
}

export interface RelayerRefundLeaf {
  isSolana: boolean;
  amountToReturn: bigint;
  chainId: bigint;
  refundAmounts: bigint[];
  leafId: bigint;
  l2TokenAddress: string;
  refundAddresses: string[];
}

export interface RelayerRefundLeafSolana {
  isSolana: boolean;
  amountToReturn: BN;
  chainId: BN;
  refundAmounts: BN[];
  leafId: BN;
  mintPublicKey: PublicKey;
  refundAccounts: PublicKey[];
}

export type RelayerRefundLeafType = RelayerRefundLeaf | RelayerRefundLeafSolana;

export function convertLeafIdToNumber(leaf: RelayerRefundLeafSolana) {
  return { ...leaf, leafId: leaf.leafId.toNumber() };
}

export function calculateRelayerRefundLeafHashUint8Array(relayData: RelayerRefundLeafSolana): string {
  const refundAmountsBuffer = Buffer.concat(
    relayData.refundAmounts.map((amount) => {
      const buf = Buffer.alloc(8);
      amount.toArrayLike(Buffer, "le", 8).copy(buf);
      return buf;
    })
  );

  const refundAccountsBuffer = Buffer.concat(relayData.refundAccounts.map((account) => account.toBuffer()));

  const contentToHash = Buffer.concat([
    relayData.amountToReturn.toArrayLike(Buffer, "le", 8),
    relayData.chainId.toArrayLike(Buffer, "le", 8),
    relayData.leafId.toArrayLike(Buffer, "le", 4),
    relayData.mintPublicKey.toBuffer(),
    refundAmountsBuffer,
    refundAccountsBuffer,
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  return relayHash;
}

export const relayerRefundHashFn = (input: RelayerRefundLeaf | RelayerRefundLeafSolana) => {
  if (!input.isSolana) {
    const abiCoder = new ethers.utils.AbiCoder();
    const encodedData = abiCoder.encode(
      [
        "tuple(uint256 leafId, uint256 chainId, uint256 amountToReturn, address l2TokenAddress, address[] refundAddresses, uint256[] refundAmounts)",
      ],
      [
        {
          leafId: input.leafId,
          chainId: input.chainId,
          amountToReturn: input.amountToReturn,
          l2TokenAddress: (input as RelayerRefundLeaf).l2TokenAddress, // Type assertion
          refundAddresses: (input as RelayerRefundLeaf).refundAddresses, // Type assertion
          refundAmounts: (input as RelayerRefundLeaf).refundAmounts, // Type assertion
        },
      ]
    );
    return ethers.utils.keccak256(encodedData);
  } else {
    return calculateRelayerRefundLeafHashUint8Array(input as RelayerRefundLeafSolana);
  }
};

export interface SlowFillLeaf {
  relayData: {
    depositor: PublicKey;
    recipient: PublicKey;
    exclusiveRelayer: PublicKey;
    inputToken: PublicKey;
    outputToken: PublicKey;
    inputAmount: BN;
    outputAmount: BN;
    originChainId: BN;
    depositId: BN;
    fillDeadline: BN;
    exclusivityDeadline: BN;
    message: Buffer;
  };
  chainId: BN;
  updatedOutputAmount: BN;
}

export function slowFillHashFn(slowFillLeaf: SlowFillLeaf): string {
  const contentToHash = Buffer.concat([
    slowFillLeaf.relayData.depositor.toBuffer(),
    slowFillLeaf.relayData.recipient.toBuffer(),
    slowFillLeaf.relayData.exclusiveRelayer.toBuffer(),
    slowFillLeaf.relayData.inputToken.toBuffer(),
    slowFillLeaf.relayData.outputToken.toBuffer(),
    slowFillLeaf.relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.originChainId.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.depositId.toArrayLike(Buffer, "le", 4),
    slowFillLeaf.relayData.fillDeadline.toArrayLike(Buffer, "le", 4),
    slowFillLeaf.relayData.exclusivityDeadline.toArrayLike(Buffer, "le", 4),
    slowFillLeaf.relayData.message,
    slowFillLeaf.chainId.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.updatedOutputAmount.toArrayLike(Buffer, "le", 8),
  ]);

  const slowFillHash = ethers.utils.keccak256(contentToHash);
  return slowFillHash;
}

export async function loadExecuteRelayerRefundLeafParams(
  program: Program<SvmSpoke>,
  caller: PublicKey,
  rootBundleId: number,
  relayerRefundLeaf: RelayerRefundLeafSolana,
  proof: number[][]
) {
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  // Close the instruction params account if the caller has used it before.
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), caller.toBuffer()],
    program.programId
  );
  const accountInfo = await program.provider.connection.getAccountInfo(instructionParams);
  if (accountInfo !== null) await program.methods.closeInstructionParams().rpc();

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("executeRelayerRefundLeafParams", {
    rootBundleId,
    relayerRefundLeaf,
    proof,
  });

  await program.methods.initializeInstructionParams(instructionParamsBytes.length).rpc();

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    await program.methods.writeInstructionParamsFragment(i, fragment).rpc();
  }
  return instructionParams;
}
