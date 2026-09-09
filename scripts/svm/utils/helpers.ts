import { AnchorProvider } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey } from "@solana/web3.js";
import { MerkleTree } from "../../../utils/MerkleTree";
import { BigNumber, ethers } from "ethers";
import { getMessageTransmitterV2Program, getSpokePoolProgram } from "../../../src/svm/web3-v1";
import HubPoolArtifact from "../../../out/HubPool.sol/HubPool.json";
import WETH9Artifact from "../../../out/WETH9.sol/WETH9.json";

export function getHubPoolContract(address: string, signerOrProvider: ethers.Signer | ethers.providers.Provider) {
  return new ethers.Contract(address, HubPoolArtifact.abi, signerOrProvider);
}

export function getBondTokenContract(address: string, signerOrProvider: ethers.Signer | ethers.providers.Provider) {
  return new ethers.Contract(address, WETH9Artifact.abi, signerOrProvider);
}

export const requireEnv = (name: string): string => {
  if (!process.env[name]) throw new Error(`Environment variable ${name} is not set`);
  return process.env[name];
};

export const formatUsdc = (amount: BigNumber): string => {
  return ethers.utils.formatUnits(amount, 6);
};

export function constructEmptyPoolRebalanceTree(chainId: BigNumber, groupIndex: number) {
  const poolRebalanceLeaf = {
    chainId,
    groupIndex: BigNumber.from(groupIndex),
    bundleLpFees: [],
    netSendAmounts: [],
    runningBalances: [],
    leafId: BigNumber.from(0),
    l1Tokens: [],
  };

  const rebalanceParamType =
    "tuple( uint256 chainId, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint256 groupIndex, uint8 leafId, address[] l1Tokens )";
  const rebalanceHashFn = (input: any) =>
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([rebalanceParamType], [input]));

  const poolRebalanceTree = new MerkleTree([poolRebalanceLeaf], rebalanceHashFn);
  return { poolRebalanceLeaf, poolRebalanceTree };
}

/**
 * Receives an attested CCTP V2 message on the SVM Spoke Pool via the CCTP V2 Message Transmitter. The spoke translates
 * the message body into a self-invoked instruction, so `selfInvokedAccounts` must list that instruction's accounts
 * (excluding the self_authority signer that the program prepends). See handle_receive_finalized_message in svm_spoke.
 */
export async function receiveCctpV2MessageOnSpoke(
  provider: AnchorProvider,
  svmSpokeProgram: ReturnType<typeof getSpokePoolProgram>,
  statePda: PublicKey,
  message: Buffer,
  attestation: Buffer,
  selfInvokedAccounts: AccountMeta[]
): Promise<string> {
  const messageTransmitterProgram = getMessageTransmitterV2Program(provider);
  const [messageTransmitterState] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter")],
    messageTransmitterProgram.programId
  );
  // CCTP V2 tracks each nonce in its own PDA seeded by the 32-byte nonce at header offset 12 of the attested message.
  const [usedNonce] = PublicKey.findProgramAddressSync(
    [Buffer.from("used_nonce"), message.subarray(12, 44)],
    messageTransmitterProgram.programId
  );
  const [selfAuthority] = PublicKey.findProgramAddressSync([Buffer.from("self_authority")], svmSpokeProgram.programId);

  const remainingAccounts: AccountMeta[] = [
    // Accounts of handle_receive_finalized_message; state authenticates the remote domain and sender.
    { pubkey: statePda, isSigner: false, isWritable: false },
    { pubkey: selfAuthority, isSigner: false, isWritable: false },
    { pubkey: svmSpokeProgram.programId, isSigner: false, isWritable: false },
    ...selfInvokedAccounts,
  ];

  return messageTransmitterProgram.methods
    .receiveMessage({ message, attestation })
    .accounts({
      payer: provider.wallet.publicKey,
      caller: provider.wallet.publicKey,
      // authority_pda, system_program and event_authority are resolved by Anchor from the IDL.
      messageTransmitter: messageTransmitterState,
      usedNonce,
      receiver: svmSpokeProgram.programId,
      program: messageTransmitterProgram.programId,
    })
    .remainingAccounts(remainingAccounts)
    .rpc();
}
