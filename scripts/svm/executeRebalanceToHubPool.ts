// This script executes root bundle on HubPool that rebalances tokens to Solana Spoke Pool. Required environment:
// - ETHERS_PROVIDER_URL: Ethereum RPC provider URL.
// - ETHERS_MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum
// - HUB_POOL_ADDRESS: Hub Pool address

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey, SystemProgram } from "@solana/web3.js";
// eslint-disable-next-line camelcase
import { BigNumber, ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { CHAIN_IDs } from "../../utils/constants";
// eslint-disable-next-line camelcase
import { HubPool__factory } from "../../typechain";
import { CIRCLE_IRIS_API_URL_DEVNET, CIRCLE_IRIS_API_URL_MAINNET } from "./utils/constants";
import { constructEmptyPoolRebalanceTree } from "./utils/helpers";

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

const [messageTransmitterState] = PublicKey.findProgramAddressSync(
  [Buffer.from("message_transmitter")],
  messageTransmitterProgram.programId
);
const [authorityPda] = PublicKey.findProgramAddressSync(
  [Buffer.from("message_transmitter_authority"), svmSpokeProgram.programId.toBuffer()],
  messageTransmitterProgram.programId
);
const [selfAuthority] = PublicKey.findProgramAddressSync([Buffer.from("self_authority")], svmSpokeProgram.programId);
const [eventAuthority] = PublicKey.findProgramAddressSync(
  [Buffer.from("__event_authority")],
  svmSpokeProgram.programId
);

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

async function executeRebalanceToHubPool(): Promise<void> {
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
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana - ${solanaCluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
  );
  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;
  const supportedEvmChainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET; // Sepolia is bridged to devnet, Ethereum to mainnet in CCTP.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== supportedEvmChainId) {
    throw new Error(`Chain ID ${evmChainId} does not match expected Solana cluster ${solanaCluster}`);
  }

  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );

  const state = await svmSpokeProgram.account.state.fetch(statePda);

  const rootBundleId = state.rootBundleId;
  const rootBundleIdBuffer = Buffer.alloc(4);
  rootBundleIdBuffer.writeUInt32LE(rootBundleId);

  const [rootBundlePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer],
    svmSpokeProgram.programId
  );

  console.log("Executing rebalance pool bundle to hub pool...");
  console.table([
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    // { Property: "l1TokenAddress", Value: l1TokenAddress },
    // { Property: "solanaTokenKey", Value: solanaTokenKey.toString() },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "netSendAmount", Value: netSendAmount.toString() },
  ]);

  // Send executeRootBundle call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    remoteTxHash = await executeRebalanceOnHubPool(solanaChainId);
  } else remoteTxHash = resumeRemoteTx;

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
    receiver: svmSpokeProgram.programId,
    systemProgram: SystemProgram.programId,
  };

  // accountMetas list to pass to remaining accounts when receiving message via CCTP.
  const remainingAccounts: AccountMeta[] = [];

  // state in HandleReceiveMessage accounts (used for remote domain and sender authentication).
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: statePda,
  });
  // self_authority in HandleReceiveMessage accounts, also signer in self-invoked CPIs.
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: selfAuthority,
  });
  // program in HandleReceiveMessage accounts.
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: svmSpokeProgram.programId,
  });

  // payer
  remainingAccounts.push({
    isSigner: true,
    isWritable: true,
    pubkey: provider.wallet.publicKey,
  });

  // state in self-invoked CPIs (state can change as a result of remote call).
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: statePda,
  });

  // root_bundle
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: rootBundlePda,
  });
  // event_authority in self-invoked CPIs (appended by Anchor with event_cpi macro).
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: eventAuthority,
  });
  // program
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: svmSpokeProgram.programId,
  });

  // Receive remote message on Solana.
  console.log("Receiving message on Solana...");
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

  const finalState = await svmSpokeProgram.account.state.fetch(statePda);
  console.log("Final state root bundle ID:", finalState.rootBundleId);
}

async function executeRebalanceOnHubPool(solanaChainId: BigNumber) {
  // Reconstruct the merkle tree for the pool rebalance.
  const { poolRebalanceLeaf, poolRebalanceTree } = constructEmptyPoolRebalanceTree(solanaChainId, 0);

  // Make sure the proposal liveness has passed, it has not been executed and rebalance root matches.
  const currentRootBundleProposal = await hubPool.connect(ethersSigner).callStatic.rootBundleProposal();
  if (currentRootBundleProposal.challengePeriodEndTimestamp > (await hubPool.callStatic.getCurrentTime()).toNumber())
    throw new Error("Not passed liveness");
  if (!currentRootBundleProposal.claimedBitMap.isZero()) throw new Error("Already claimed");
  if (currentRootBundleProposal.poolRebalanceRoot !== poolRebalanceTree.getHexRoot())
    throw new Error("Rebalance root mismatch");

  // Execute the rebalance bundle on the HubPool.
  const tx = await hubPool.connect(ethersSigner).executeRootBundle(
    solanaChainId,
    0, // groupIndex
    poolRebalanceLeaf.bundleLpFees,
    poolRebalanceLeaf.netSendAmounts,
    poolRebalanceLeaf.runningBalances,
    poolRebalanceLeaf.leafId,
    poolRebalanceLeaf.l1Tokens,
    poolRebalanceTree.getHexProof(poolRebalanceLeaf)
  );
  console.log(`✔️ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log("✔️ tx confirmed");

  return tx.hash;
}

// Run the executeRebalanceToHubPool function
executeRebalanceToHubPool();
