import { BN, Program, workspace } from "@coral-xyz/anchor";
import {
  airdropFactory,
  Commitment,
  CompilableTransactionMessage,
  createSolanaRpc,
  createSolanaRpcSubscriptions,
  createTransactionMessage,
  generateKeyPairSigner,
  getSignatureFromTransaction,
  lamports,
  pipe,
  Rpc,
  RpcSubscriptions,
  RpcTransport,
  sendAndConfirmTransactionFactory,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  SignatureNotificationsApi,
  signTransactionMessageWithSigners,
  SlotNotificationsApi,
  SolanaRpcApiFromTransport,
  TransactionMessageWithBlockhashLifetime,
  TransactionSigner,
} from "@solana/kit";
import { AccountMeta, Keypair, PublicKey } from "@solana/web3.js";
import * as crypto from "crypto";
import { BigNumber, ethers } from "ethers";
import {
  AcrossPlusMessageCoder,
  calculateRelayHashUint8Array,
  findProgramAddress,
  MulticallHandlerCoder,
  readEvents,
  readProgramEvents,
  relayerRefundHashFn,
} from "../../src/svm";
import { MulticallHandler } from "../../target/types/multicall_handler";

import { MerkleTree } from "@uma/common";
import { RelayerRefundLeaf, RelayerRefundLeafType } from "../../src/types/svm";

export { calculateRelayHashUint8Array, findProgramAddress, readEvents, readProgramEvents };

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

export const signAndSendTransaction = async (
  rpcClient: RpcClient,
  transactionMessage: CompilableTransactionMessage & TransactionMessageWithBlockhashLifetime,
  commitment: Commitment = "confirmed"
) => {
  const signedTransaction = await signTransactionMessageWithSigners(transactionMessage);
  const signature = getSignatureFromTransaction(signedTransaction);
  await sendAndConfirmTransactionFactory(rpcClient)(signedTransaction, {
    commitment,
  });
  return signature;
};

export const createDefaultTransaction = async (rpcClient: RpcClient, signer: TransactionSigner) => {
  const { value: latestBlockhash } = await rpcClient.rpc.getLatestBlockhash().send();
  return pipe(
    createTransactionMessage({ version: 0 }),
    (tx) => setTransactionMessageFeePayerSigner(signer, tx),
    (tx) => setTransactionMessageLifetimeUsingBlockhash(latestBlockhash, tx)
  );
};

export const createDefaultSolanaClient = () => {
  const rpc = createSolanaRpc("http://127.0.0.1:8899");
  const rpcSubscriptions = createSolanaRpcSubscriptions("ws://127.0.0.1:8900");
  return { rpc, rpcSubscriptions };
};

export type RpcClient = {
  rpc: Rpc<SolanaRpcApiFromTransport<RpcTransport>>;
  rpcSubscriptions: RpcSubscriptions<SignatureNotificationsApi & SlotNotificationsApi>;
};

export const generateKeyPairSignerWithSol = async (rpcClient: RpcClient, putativeLamports: bigint = 1_000_000_000n) => {
  const signer = await generateKeyPairSigner();
  await airdropFactory(rpcClient)({
    recipientAddress: signer.address,
    lamports: lamports(putativeLamports),
    commitment: "confirmed",
  });
  return signer;
};
