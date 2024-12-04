// This script executes root bundle on HubPool that rebalances tokens to Solana Spoke Pool. Required environment:
// - ETHERS_PROVIDER_URL: Ethereum RPC provider URL.
// - ETHERS_MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum
// - HUB_POOL_ADDRESS: Hub Pool address

import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey, SystemProgram } from "@solana/web3.js";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
// eslint-disable-next-line camelcase
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../../utils/constants";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { evmAddressToPublicKey } from "../../src/SvmUtils";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { TokenMessengerMinter } from "../../target/types/token_messenger_minter";
import { ethers, BigNumber } from "ethers";
// eslint-disable-next-line camelcase
import { HubPool__factory } from "../../typechain";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  SOLANA_USDC_DEVNET,
  SOLANA_USDC_MAINNET,
} from "./utils/constants";
import { constructSimpleRebalanceTree } from "./utils/poolRebalanceTree";
import { decodeMessageHeader, getMessages } from "../../test/svm/cctpHelpers";

// Set up Solana provider.
const provider = AnchorProvider.env();
anchor.setProvider(provider);

// Get Solana programs.
const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
const messageTransmitterIdl = require("../../target/idl/message_transmitter.json");
const messageTransmitterProgram = new Program<MessageTransmitter>(messageTransmitterIdl, provider);
const tokenMessengerMinterIdl = require("../../target/idl/token_messenger_minter.json");
const tokenMessengerMinterProgram = new Program<TokenMessengerMinter>(tokenMessengerMinterIdl, provider);

// Set up Ethereum provider.
if (!process.env.ETHERS_PROVIDER_URL) {
  throw new Error("Environment variable ETHERS_PROVIDER_URL is not set");
}
const ethersProvider = new ethers.providers.JsonRpcProvider(process.env.ETHERS_PROVIDER_URL);
if (!process.env.ETHERS_MNEMONIC) {
  throw new Error("Environment variable ETHERS_MNEMONIC is not set");
}
const ethersSigner = ethers.Wallet.fromMnemonic(process.env.ETHERS_MNEMONIC).connect(ethersProvider);

// Get the HubPool contract instance.
if (!process.env.HUB_POOL_ADDRESS) {
  throw new Error("Environment variable HUB_POOL_ADDRESS is not set");
}
const hubPoolAddress = ethers.utils.getAddress(process.env.HUB_POOL_ADDRESS);
const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);

// CCTP domains.
const remoteDomain = 0; // Ethereum

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("netSendAmount", { type: "string", demandOption: false, describe: "Net send amount to spoke" })
  .option("resumeRemoteTx", { type: "string", demandOption: false, describe: "Resume receiving remote tx" })
  .check((argv) => {
    if (argv.netSendAmount !== undefined && argv.resumeRemoteTx !== undefined) {
      throw new Error("Options --netSendAmount and --resumeRemoteTx are mutually exclusive");
    }
    if (argv.netSendAmount === undefined && argv.resumeRemoteTx === undefined) {
      throw new Error("One of the options --netSendAmount or --resumeRemoteTx is required");
    }
    return true;
  }).argv;

async function executeRebalanceToSpokePool(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(0); // Seed is always 0 for the state account PDA in public networks.
  const netSendAmount = resolvedArgv.netSendAmount ? BigNumber.from(resolvedArgv.netSendAmount) : BigNumber.from(0);
  const resumeRemoteTx = resolvedArgv.resumeRemoteTx;

  // Resolve Solana cluster, EVM chain ID, Iris API URL and USDC addresses.
  let isDevnet: boolean;
  const solanaRpcEndpoint = provider.connection.rpcEndpoint;
  if (solanaRpcEndpoint.includes("devnet")) isDevnet = true;
  else if (solanaRpcEndpoint.includes("mainnet")) isDevnet = false;
  else throw new Error(`Unsupported solanaCluster endpoint: ${solanaRpcEndpoint}`);
  const solanaCluster = isDevnet ? "devnet" : "mainnet";
  const solanaChainId = BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${solanaCluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
  );
  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;
  const supportedEvmChainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET; // Sepolia is bridged to devnet, Ethereum to mainnet in CCTP.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== supportedEvmChainId) {
    throw new Error(`Chain ID ${evmChainId} does not match expected Solana cluster ${solanaCluster}`);
  }
  const l1TokenAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[evmChainId];
  const solanaTokenKey = isDevnet ? new PublicKey(SOLANA_USDC_DEVNET) : new PublicKey(SOLANA_USDC_MAINNET);

  console.log("Executing rebalance pool bundle to spoke...");
  console.table([
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "l1TokenAddress", Value: l1TokenAddress },
    { Property: "solanaTokenKey", Value: solanaTokenKey.toString() },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "netSendAmount", Value: netSendAmount.toString() },
  ]);

  // Send executeRootBundle call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    remoteTxHash = await executeRebalanceOnHubPool(l1TokenAddress, netSendAmount, solanaChainId);
  } else remoteTxHash = resumeRemoteTx;

  // Get Solana accounts required to receive tokens over CCTP.
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );
  const vault = getAssociatedTokenAddressSync(solanaTokenKey, statePda, true);
  const [messageTransmitterState] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter")],
    messageTransmitterProgram.programId
  );
  const [authorityPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter_authority"), tokenMessengerMinterProgram.programId.toBuffer()],
    messageTransmitterProgram.programId
  );
  const [tokenMessengerAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from("token_messenger")],
    tokenMessengerMinterProgram.programId
  );
  const [remoteTokenMessengerKey] = PublicKey.findProgramAddressSync(
    [Buffer.from("remote_token_messenger"), Buffer.from(remoteDomain.toString())],
    tokenMessengerMinterProgram.programId
  );
  const [tokenMinterAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from("token_minter")],
    tokenMessengerMinterProgram.programId
  );
  const [localToken] = PublicKey.findProgramAddressSync(
    [Buffer.from("local_token"), solanaTokenKey.toBuffer()],
    tokenMessengerMinterProgram.programId
  );
  const [tokenPair] = PublicKey.findProgramAddressSync(
    [Buffer.from("token_pair"), Buffer.from(remoteDomain.toString()), evmAddressToPublicKey(l1TokenAddress).toBuffer()],
    tokenMessengerMinterProgram.programId
  );
  const [custodyTokenAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from("custody"), solanaTokenKey.toBuffer()],
    tokenMessengerMinterProgram.programId
  );
  const [tokenMessengerEventAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("__event_authority")],
    tokenMessengerMinterProgram.programId
  );

  // Fetch attestation from CCTP attestation service.
  const attestationResponse = await getMessages(remoteTxHash, remoteDomain, irisApiUrl);
  const { attestation, message } = attestationResponse.messages[0];
  console.log("CCTP attestation response:", attestationResponse.messages[0]);

  // Accounts in CCTP message_transmitter receive_message instruction.
  const nonce = decodeMessageHeader(Buffer.from(message.replace("0x", ""), "hex")).nonce;
  const usedNonces = (await messageTransmitterProgram.methods
    .getNoncePda({
      nonce: new BN(nonce.toString()),
      sourceDomain: remoteDomain,
    })
    .accounts({
      messageTransmitter: messageTransmitterState,
    })
    .view()) as PublicKey;
  const receiveMessageAccounts = {
    payer: provider.wallet.publicKey,
    caller: provider.wallet.publicKey,
    authorityPda,
    messageTransmitter: messageTransmitterState,
    usedNonces,
    receiver: tokenMessengerMinterProgram.programId,
    systemProgram: SystemProgram.programId,
  };

  // accountMetas list to pass to remaining accounts when receiving token bridge message via CCTP.
  const remainingAccounts: AccountMeta[] = [];
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: tokenMessengerAccount,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: remoteTokenMessengerKey,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: tokenMinterAccount,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: localToken,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: tokenPair,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: vault,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: custodyTokenAccount,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: TOKEN_PROGRAM_ID,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: tokenMessengerEventAuthority,
  });
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: tokenMessengerMinterProgram.programId,
  });

  // Receive tokens on Solana.
  console.log(`Receiving ${netSendAmount.toString()} tokens on Solana...`);
  const receiveMessageTx = await messageTransmitterProgram.methods
    .receiveMessage({
      message: Buffer.from(message.replace("0x", ""), "hex"),
      attestation: Buffer.from(attestation.replace("0x", ""), "hex"),
    })
    .accounts(receiveMessageAccounts as any)
    .remainingAccounts(remainingAccounts)
    .rpc();
  console.log("\nReceived remote message");
  console.log("Your transaction signature", receiveMessageTx);
}

async function executeRebalanceOnHubPool(l1TokenAddress: string, netSendAmount: BigNumber, solanaChainId: BigNumber) {
  // Reconstruct the merkle tree for the pool rebalance.
  const { poolRebalanceTree, poolRebalanceLeaf } = constructSimpleRebalanceTree(
    l1TokenAddress,
    netSendAmount,
    solanaChainId
  );

  // Make sure the proposal liveness has passed, it has not been executed and rebalance root matches.
  const currentRootBundleProposal = await hubPool.connect(ethersSigner).callStatic.rootBundleProposal();
  if (currentRootBundleProposal.challengePeriodEndTimestamp > (await hubPool.callStatic.getCurrentTime()).toNumber())
    throw new Error("Not passed liveness");
  if (!currentRootBundleProposal.claimedBitMap.isZero()) throw new Error("Already claimed");
  if (currentRootBundleProposal.poolRebalanceRoot !== poolRebalanceTree.getHexRoot())
    throw new Error("Rebalance root mismatch");

  // Execute the rebalance bundle on the HubPool.
  console.log(`Executing ${netSendAmount.toString()} rebalance to spoke pool:`);
  const tx = await hubPool
    .connect(ethersSigner)
    .executeRootBundle(
      poolRebalanceLeaf.chainId,
      poolRebalanceLeaf.groupIndex,
      poolRebalanceLeaf.bundleLpFees,
      poolRebalanceLeaf.netSendAmounts,
      poolRebalanceLeaf.runningBalances,
      poolRebalanceLeaf.leafId,
      poolRebalanceLeaf.l1Tokens,
      poolRebalanceTree.getHexProof(poolRebalanceLeaf)
    );
  console.log(`✔️ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log(`✔️ tx confirmed`);

  return tx.hash;
}

// Run the executeRebalanceToSpokePool function
executeRebalanceToSpokePool();