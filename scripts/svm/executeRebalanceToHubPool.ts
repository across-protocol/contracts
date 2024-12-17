/**
 * Script: Execute USDC Rebalance to Hub Pool
 *
 * This script executes a previously proposed root bundle on the Hub Pool to rebalance USDC from the Solana Spoke Pool
 * to the Ethereum Hub Pool. It handles CCTP attestations, relayer refund leaf execution, and prepares pending
 * liabilities for bridging back to the Hub Pool.
 *
 * Required Environment Variables:
 * - MNEMONIC: Wallet mnemonic to sign the Ethereum transaction.
 * - HUB_POOL_ADDRESS: Ethereum address of the Hub Pool.
 * - NODE_URL_${CHAIN_ID}: Ethereum RPC URL (must point to the Mainnet or Sepolia depending on Solana cluster).
 *
 * Required Arguments:
 * - `--netSendAmount`: The unscaled amount of USDC to rebalance (e.g., for USDC with 6 decimals, 1 = 0.000001 USDC).
 * - `--resumeRemoteTx`: (Optional) Hash of a previously submitted remote transaction to resume.
 *
 * Example Usage:
 * NODE_URL_11155111=$NODE_URL_11155111 \
 * MNEMONIC=$MNEMONIC \
 * HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS \
 * anchor run executeRebalanceToHubPool \
 * --provider.cluster "devnet" \
 * --provider.wallet $SOLANA_PKEY_PATH \
 * -- --netSendAmount 7
 *
 * Note:
 * - Ensure all required environment variables are properly configured.
 */

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program } from "@coral-xyz/anchor";
import { ASSOCIATED_TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import {
  AccountMeta,
  AddressLookupTableProgram,
  ComputeBudgetProgram,
  PublicKey,
  SystemProgram,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
// eslint-disable-next-line camelcase
import { BigNumber, ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { CHAIN_IDs } from "../../utils/constants";
// eslint-disable-next-line camelcase
import { HubPool__factory } from "../../typechain";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  SOLANA_SPOKE_STATE_SEED,
  SOLANA_USDC_DEVNET,
  SOLANA_USDC_MAINNET,
} from "./utils/constants";
import {
  constructEmptyPoolRebalanceTree,
  constructSimpleRebalanceTreeToHubPool,
  formatUsdc,
  getSolanaChainId,
  requireEnv,
  isSolanaDevnet,
} from "./utils/helpers";

import { getNodeUrl, MerkleTree } from "@uma/common";
import { decodeMessageHeader, getMessages } from "../../test/svm/cctpHelpers";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../src/types/svm";
import { loadExecuteRelayerRefundLeafParams } from "../../src/svm";

// Set up Solana provider.
const provider = AnchorProvider.env();
anchor.setProvider(provider);

// Get Solana programs.
const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
const messageTransmitterIdl = require("../../target/idl/message_transmitter.json");
const messageTransmitterProgram = new Program<MessageTransmitter>(messageTransmitterIdl, provider);

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

// Set up Ethereum provider and signer.
const isDevnet = isSolanaDevnet(provider);
const nodeURL = isDevnet ? getNodeUrl("sepolia", true) : getNodeUrl("mainnet", true);
const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

// Get the HubPool contract instance.
const hubPoolAddress = ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS"));
const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);

// CCTP domains.
const ethereumDomain = 0; // Ethereum

// Parse arguments
const argv = yargs(hideBin(process.argv))
  // Net send amount is always required as we need it to calculate the relayer refund leaf.
  .option("netSendAmount", { type: "string", demandOption: true, describe: "Net send amount to Hub Pool" })
  .option("resumeRemoteTx", { type: "string", demandOption: false, describe: "Resume receiving remote tx" }).argv;

async function executeRebalanceToHubPool(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = SOLANA_SPOKE_STATE_SEED; // Seed is always 0 for the state account PDA in public networks.
  const netSendAmount = BigNumber.from(resolvedArgv.netSendAmount);
  const resumeRemoteTx = resolvedArgv.resumeRemoteTx;

  // Resolve Solana cluster, EVM chain ID, Iris API URL and USDC addresses.
  const solanaCluster = isDevnet ? "devnet" : "mainnet";
  const solanaChainId = getSolanaChainId(solanaCluster);
  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;
  const supportedEvmChainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET; // Sepolia is bridged to devnet, Ethereum to mainnet in CCTP.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== supportedEvmChainId) {
    throw new Error(`Chain ID ${evmChainId} does not match expected Solana cluster ${solanaCluster}`);
  }

  const svmUsdc = isDevnet ? SOLANA_USDC_DEVNET : SOLANA_USDC_MAINNET;

  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );

  const state = await svmSpokeProgram.account.state.fetch(statePda);

  const [rootBundlePda] = getRootBundlePda(state.rootBundleId, seed);

  console.log("Executing rebalance to hub pool...");
  console.table([
    { Property: "isTestnet", Value: isDevnet },
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "svmProviderPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "netSendAmount (formatted)", Value: formatUsdc(netSendAmount) },
  ]);

  // Send executeRootBundle call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    remoteTxHash = await executeRootBalanceOnHubPool(solanaChainId);
  } else remoteTxHash = resumeRemoteTx;

  // Fetch attestation from CCTP attestation service.
  const attestationResponse = await getMessages(remoteTxHash, ethereumDomain, irisApiUrl);
  const { attestation, message } = attestationResponse.messages[0];
  console.log("CCTP attestation response:", attestationResponse.messages[0]);

  // Accounts in CCTP message_transmitter receive_message instruction.
  const nonce = decodeMessageHeader(Buffer.from(message.replace("0x", ""), "hex")).nonce;
  const usedNonces = (await messageTransmitterProgram.methods
    .getNoncePda({
      nonce: new BN(nonce.toString()),
      sourceDomain: ethereumDomain,
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

  // system_program
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: SystemProgram.programId,
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

  // The state stores the next root bundle ID, so we need to subtract one to get the last executed root bundle ID.
  const lastRootBundleId = finalState.rootBundleId - 1;

  // Reconstruct the merkle tree for the relayer refund leaf.
  const { merkleTree, leaves } = constructSimpleRebalanceTreeToHubPool(
    netSendAmount,
    solanaChainId,
    new PublicKey(svmUsdc)
  );
  const [rootBundlePdaNew] = getRootBundlePda(lastRootBundleId, seed);

  console.log(`Executing relayer refund leaf for root bundle ID: ${lastRootBundleId}`);

  await executeRelayerRefundLeaf(
    provider.wallet as anchor.Wallet,
    svmSpokeProgram,
    statePda,
    rootBundlePdaNew,
    leaves[0],
    merkleTree,
    new PublicKey(svmUsdc),
    lastRootBundleId
  );

  console.log("✅ executed relayer refund leaf");

  const [transferLiability] = PublicKey.findProgramAddressSync(
    [Buffer.from("transfer_liability"), new PublicKey(svmUsdc).toBuffer()],
    svmSpokeProgram.programId
  );

  const liability = await svmSpokeProgram.account.transferLiability.fetch(transferLiability);
  console.log(`Pending transfer liability: ${formatUsdc(BigNumber.from(liability.pendingToHubPool.toString()))} USDC`);
  console.log("You can now send the pending liability to hub pool with bridgeLiabilityToHubPool.ts");
}

function getRootBundlePda(rootBundleId: number, seed: BN) {
  const rootBundleIdBuffer = Buffer.alloc(4);
  rootBundleIdBuffer.writeUInt32LE(rootBundleId);
  return PublicKey.findProgramAddressSync(
    [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer],
    svmSpokeProgram.programId
  );
}

async function executeRootBalanceOnHubPool(solanaChainId: BigNumber) {
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
  console.log(`✅ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log("✅ tx confirmed");

  return tx.hash;
}

async function executeRelayerRefundLeaf(
  signer: anchor.Wallet,
  program: Program<SvmSpoke>,
  statePda: PublicKey,
  rootBundle: PublicKey,
  relayerRefundLeaf: RelayerRefundLeafSolana,
  merkleTree: MerkleTree<RelayerRefundLeafType>,
  inputToken: PublicKey,
  rootBundleId: number
) {
  // Execute the single leaf
  const proof = merkleTree.getProof(relayerRefundLeaf).map((p) => Array.from(p));
  const leaf = relayerRefundLeaf as RelayerRefundLeafSolana;

  const vault = getAssociatedTokenAddressSync(
    inputToken,
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  // Derive the transferLiability PDA
  const [transferLiability] = PublicKey.findProgramAddressSync(
    [Buffer.from("transfer_liability"), inputToken.toBuffer()],
    program.programId
  );

  // Load the instruction parameters
  const proofAsNumbers = proof.map((p) => Array.from(p));
  console.log("loading execute relayer refund leaf params...");

  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), signer.publicKey.toBuffer()],
    program.programId
  );

  const staticAccounts = {
    instructionParams,
    state: statePda,
    rootBundle: rootBundle,
    signer: signer.publicKey,
    vault: vault,
    tokenProgram: TOKEN_PROGRAM_ID,
    mint: inputToken,
    transferLiability,
    systemProgram: anchor.web3.SystemProgram.programId,
    // Appended by Acnhor `event_cpi` macro:
    eventAuthority: PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId)[0],
    program: program.programId,
  };

  const refundAccounts: PublicKey[] = [];

  // Consolidate all above addresses into a single array for the  Address Lookup Table (ALT).
  const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
    authority: signer.publicKey,
    payer: signer.publicKey,
    recentSlot: await provider.connection.getSlot(),
  });

  // Submit the ALT creation transaction
  await anchor.web3.sendAndConfirmTransaction(
    provider.connection,
    new anchor.web3.Transaction().add(lookupTableInstruction),
    [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
    { skipPreflight: true }
  );

  const lookupAddresses = [...Object.values(staticAccounts), ...refundAccounts];

  // Create the transaction with the compute budget expansion instruction & use extended ALT account.

  // Extend the ALT with all accounts
  const maxExtendedAccounts = 30; // Maximum number of accounts that can be added to ALT in a single transaction.
  for (let i = 0; i < lookupAddresses.length; i += maxExtendedAccounts) {
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: signer.publicKey,
      payer: signer.publicKey,
      addresses: lookupAddresses.slice(i, i + maxExtendedAccounts),
    });

    await anchor.web3.sendAndConfirmTransaction(
      provider.connection,
      new anchor.web3.Transaction().add(extendInstruction),
      [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
      { skipPreflight: true }
    );
  }
  // Fetch the AddressLookupTableAccount
  const lookupTableAccount = (await provider.connection.getAddressLookupTable(lookupTableAddress)).value;
  if (!lookupTableAccount) {
    throw new Error("AddressLookupTableAccount not fetched");
  }

  await loadExecuteRelayerRefundLeafParams(program, signer.publicKey, rootBundleId, leaf, proofAsNumbers);

  console.log(`loaded execute relayer refund leaf params ${instructionParams}. \nExecuting relayer refund leaf...`);

  const executeInstruction = await program.methods
    .executeRelayerRefundLeaf()
    .accounts(staticAccounts)
    .remainingAccounts([])
    .instruction();

  // Create the versioned transaction
  const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 500_000 });
  const versionedTx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: signer.publicKey,
      recentBlockhash: (await provider.connection.getLatestBlockhash()).blockhash,
      instructions: [computeBudgetInstruction, executeInstruction],
    }).compileToV0Message([lookupTableAccount])
  );

  // Sign and submit the versioned transaction
  versionedTx.sign([(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer]);
  const tx = await provider.connection.sendTransaction(versionedTx);
  console.log(`Execute relayer refund leaf transaction sent: ${tx}`);

  // Close the instruction parameters account
  console.log("Closing instruction params...");
  await new Promise((resolve) => setTimeout(resolve, 15000)); // Wait for the previous transaction to be processed.
  const closeInstructionParamsTx = await (program.methods.closeInstructionParams() as any)
    .accounts({ signer: signer.publicKey, instructionParams: instructionParams })
    .rpc();
  console.log(`Close instruction params transaction sent: ${closeInstructionParamsTx}`);
  // Note we cant close the lookup table account as it needs to be both deactivated and expired at to do this.
}

// Run the executeRebalanceToHubPool function
executeRebalanceToHubPool();
