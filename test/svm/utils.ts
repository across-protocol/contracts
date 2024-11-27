import { BN, Program, workspace } from "@coral-xyz/anchor";
import {
  AccountMeta,
  Keypair,
  PublicKey,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import { BigNumber, ethers } from "ethers";
import * as crypto from "crypto";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { MulticallHandler } from "../../target/types/multicall_handler";

import {
  readEvents,
  readProgramEvents,
  calculateRelayHashUint8Array,
  findProgramAddress,
  LargeAccountsCoder,
  MulticallHandlerCoder,
  AcrossPlusMessageCoder,
} from "../../src/SvmUtils";
import { MerkleTree } from "@uma/common";
import { RelayData } from "./SvmSpoke.common";

export { readEvents, readProgramEvents, calculateRelayHashUint8Array, findProgramAddress };

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
  amountToReturn: BigNumber;
  chainId: BigNumber;
  refundAmounts: BigNumber[];
  leafId: BigNumber;
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
  refundAddresses: PublicKey[];
}

export type RelayerRefundLeafType = RelayerRefundLeaf | RelayerRefundLeafSolana;

export function convertLeafIdToNumber(leaf: RelayerRefundLeafSolana) {
  return { ...leaf, leafId: leaf.leafId.toNumber() };
}

export function buildRelayerRefundMerkleTree({
  totalEvmDistributions,
  totalSolanaDistributions,
  mixLeaves,
  chainId,
  mint,
  svmRelayers,
  evmRelayers,
  evmTokenAddress,
  evmRefundAmounts,
  svmRefundAmounts,
}: {
  totalEvmDistributions: number;
  totalSolanaDistributions: number;
  chainId: number;
  mixLeaves?: boolean;
  mint?: PublicKey;
  svmRelayers?: PublicKey[];
  evmRelayers?: string[];
  evmTokenAddress?: string;
  evmRefundAmounts?: BigNumber[];
  svmRefundAmounts?: BN[];
}): { relayerRefundLeaves: RelayerRefundLeafType[]; merkleTree: MerkleTree<RelayerRefundLeafType> } {
  const relayerRefundLeaves: RelayerRefundLeafType[] = [];

  const createSolanaLeaf = (index: number) => ({
    isSolana: true,
    leafId: new BN(index),
    chainId: new BN(chainId),
    amountToReturn: new BN(0),
    mintPublicKey: mint ?? Keypair.generate().publicKey,
    refundAddresses: svmRelayers || [Keypair.generate().publicKey, Keypair.generate().publicKey],
    refundAmounts: svmRefundAmounts || [new BN(randomBigInt(2).toString()), new BN(randomBigInt(2).toString())],
  });

  const createEvmLeaf = (index: number) =>
    ({
      isSolana: false,
      leafId: BigNumber.from(index),
      chainId: BigNumber.from(chainId),
      amountToReturn: BigNumber.from(0),
      l2TokenAddress: evmTokenAddress ?? randomAddress(),
      refundAddresses: evmRelayers || [randomAddress(), randomAddress()],
      refundAmounts: evmRefundAmounts || [BigNumber.from(randomBigInt()), BigNumber.from(randomBigInt())],
    } as RelayerRefundLeaf);

  if (mixLeaves) {
    let solanaIndex = 0;
    let evmIndex = 0;
    const totalDistributions = totalSolanaDistributions + totalEvmDistributions;
    for (let i = 0; i < totalDistributions; i++) {
      if (solanaIndex < totalSolanaDistributions && (i % 2 === 0 || evmIndex >= totalEvmDistributions)) {
        relayerRefundLeaves.push(createSolanaLeaf(solanaIndex));
        solanaIndex++;
      } else if (evmIndex < totalEvmDistributions) {
        relayerRefundLeaves.push(createEvmLeaf(evmIndex));
        evmIndex++;
      }
    }
  } else {
    for (let i = 0; i < totalSolanaDistributions; i++) {
      relayerRefundLeaves.push(createSolanaLeaf(i));
    }
    for (let i = 0; i < totalEvmDistributions; i++) {
      relayerRefundLeaves.push(createEvmLeaf(i + totalSolanaDistributions));
    }
  }

  const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

  return { relayerRefundLeaves, merkleTree };
}

export function calculateRelayerRefundLeafHashUint8Array(relayData: RelayerRefundLeafSolana): string {
  const refundAmountsBuffer = Buffer.concat(
    relayData.refundAmounts.map((amount) => {
      const buf = Buffer.alloc(8);
      amount.toArrayLike(Buffer, "le", 8).copy(buf);
      return buf;
    })
  );

  const refundAddressesBuffer = Buffer.concat(relayData.refundAddresses.map((address) => address.toBuffer()));

  // TODO: We better consider reusing Borch serializer in production.
  const contentToHash = Buffer.concat([
    // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves can never be played on SVM and vice versa.
    Buffer.alloc(64, 0),
    relayData.amountToReturn.toArrayLike(Buffer, "le", 8),
    relayData.chainId.toArrayLike(Buffer, "le", 8),
    new BN(relayData.refundAmounts.length).toArrayLike(Buffer, "le", 4),
    refundAmountsBuffer,
    relayData.leafId.toArrayLike(Buffer, "le", 4),
    relayData.mintPublicKey.toBuffer(),
    new BN(relayData.refundAddresses.length).toArrayLike(Buffer, "le", 4),
    refundAddressesBuffer,
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  return relayHash;
}

export const relayerRefundHashFn = (input: RelayerRefundLeaf | RelayerRefundLeafSolana) => {
  if (!input.isSolana) {
    const abiCoder = new ethers.utils.AbiCoder();
    const encodedData = abiCoder.encode(
      [
        "tuple( uint256 amountToReturn, uint256 chainId, uint256[] refundAmounts, uint256 leafId, address l2TokenAddress, address[] refundAddresses)",
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
    depositId: number[];
    fillDeadline: number;
    exclusivityDeadline: number;
    message: Buffer;
  };
  chainId: BN;
  updatedOutputAmount: BN;
}

// TODO: We better consider reusing Borch serializer in production.
export function slowFillHashFn(slowFillLeaf: SlowFillLeaf): string {
  const contentToHash = Buffer.concat([
    // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves can never be played on SVM and vice versa.
    Buffer.alloc(64, 0),
    slowFillLeaf.relayData.depositor.toBuffer(),
    slowFillLeaf.relayData.recipient.toBuffer(),
    slowFillLeaf.relayData.exclusiveRelayer.toBuffer(),
    slowFillLeaf.relayData.inputToken.toBuffer(),
    slowFillLeaf.relayData.outputToken.toBuffer(),
    slowFillLeaf.relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(slowFillLeaf.relayData.depositId),
    new BN(slowFillLeaf.relayData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(slowFillLeaf.relayData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    new BN(slowFillLeaf.relayData.message.length).toArrayLike(Buffer, "le", 4),
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

export async function closeInstructionParams(program: Program<SvmSpoke>, signer: Keypair) {
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), signer.publicKey.toBuffer()],
    program.programId
  );
  const accountInfo = await program.provider.connection.getAccountInfo(instructionParams);
  if (accountInfo !== null) {
    const closeIx = await program.methods.closeInstructionParams().accounts({ signer: signer.publicKey }).instruction();
    await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(closeIx), [signer]);
  }
}

export async function createFillV3RelayParamsInstructions(
  program: Program<SvmSpoke>,
  signer: PublicKey,
  relayData: RelayData,
  repaymentChainId: BN,
  repaymentAddress: PublicKey
) {
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("fillV3RelayParams", {
    relayData,
    repaymentChainId,
    repaymentAddress,
  });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods.initializeInstructionParams(instructionParamsBytes.length).accounts({ signer }).instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods.writeInstructionParamsFragment(i, fragment).accounts({ signer }).instruction()
    );
  }

  const closeInstruction = await program.methods.closeInstructionParams().accounts({ signer }).instruction();

  return { loadInstructions, closeInstruction };
}

export async function loadFillV3RelayParams(
  program: Program<SvmSpoke>,
  signer: Keypair,
  relayData: RelayData,
  repaymentChainId: BN,
  repaymentAddress: PublicKey
) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const { loadInstructions } = await createFillV3RelayParamsInstructions(
    program,
    signer.publicKey,
    relayData,
    repaymentChainId,
    repaymentAddress
  );
  for (let i = 0; i < loadInstructions.length; i += 1) {
    await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(loadInstructions[i]), [signer]);
  }
}

export async function loadRequestV3SlowFillParams(program: Program<SvmSpoke>, signer: Keypair, relayData: RelayData) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("requestV3SlowFillParams", { relayData });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods
      .initializeInstructionParams(instructionParamsBytes.length)
      .accounts({ signer: signer.publicKey })
      .instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods
        .writeInstructionParamsFragment(i, fragment)
        .accounts({ signer: signer.publicKey })
        .instruction()
    );
  }

  return loadInstructions;
}

export async function loadExecuteV3SlowRelayLeafParams(
  program: Program<SvmSpoke>,
  signer: Keypair,
  slowFillLeaf: SlowFillLeaf,
  rootBundleId: number,
  proof: number[][]
) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("executeV3SlowRelayLeafParams", {
    slowFillLeaf,
    rootBundleId,
    proof,
  });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods
      .initializeInstructionParams(instructionParamsBytes.length)
      .accounts({ signer: signer.publicKey })
      .instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods
        .writeInstructionParamsFragment(i, fragment)
        .accounts({ signer: signer.publicKey })
        .instruction()
    );
  }

  return loadInstructions;
}

export function intToU8Array32(num: number): number[] {
  if (!Number.isInteger(num) || num < 0) {
    throw new Error("Input must be a non-negative integer");
  }

  const u8Array = new Array(32).fill(0);
  let i = 0;
  while (num > 0 && i < 32) {
    u8Array[i++] = num & 0xff; // Get least significant byte
    num >>= 8; // Shift right by 8 bits
  }

  return u8Array;
}

export function u8Array32ToInt(u8Array: Uint8Array | number[]): bigint {
  const isValidArray = (arr: any): arr is number[] => Array.isArray(arr) && arr.every(Number.isInteger);

  if ((u8Array instanceof Uint8Array || isValidArray(u8Array)) && u8Array.length === 32) {
    return Array.from(u8Array).reduce<bigint>((num, byte, i) => num | (BigInt(byte) << BigInt(i * 8)), 0n);
  }

  throw new Error("Input must be a Uint8Array or an array of 32 numbers.");
}

// Encodes empty list of multicall handler instructions to be used as a test message field for fills.
export function testAcrossPlusMessage() {
  const handlerProgram = workspace.MulticallHandler as Program<MulticallHandler>;
  const multicallHandlerCoder = new MulticallHandlerCoder([]);
  const handlerMessage = multicallHandlerCoder.encode();
  const message = new AcrossPlusMessageCoder({
    handler: handlerProgram.programId,
    readOnlyLen: multicallHandlerCoder.readOnlyLen,
    valueAmount: new BN(0),
    accounts: multicallHandlerCoder.compiledMessage.accountKeys,
    handlerMessage,
  });
  const encodedMessage = message.encode();
  const fillRemainingAccounts: AccountMeta[] = [
    { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
    ...multicallHandlerCoder.compiledKeyMetas,
  ];
  return { encodedMessage, fillRemainingAccounts };
}

export function hashNonEmptyMessage(message: Buffer) {
  if (message.length > 0) {
    const hash = ethers.utils.keccak256(message);
    return Uint8Array.from(Buffer.from(hash.slice(2), "hex"));
  }
  // else return zeroed bytes32
  return new Uint8Array(32);
}
