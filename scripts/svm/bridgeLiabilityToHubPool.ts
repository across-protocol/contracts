/**
 * Script: Bridge USDC Liability to Hub Pool
 *
 * This script bridges pending USDC liabilities from the Solana Spoke Pool
 * to the Ethereum Hub Pool using the CCTP (Circle Cross-Chain Transfer Protocol).
 * It manages CCTP message attestations, verifies transfer completion, and
 * updates the Hub Pool’s USDC balance.
 *
 * Required Environment Variables:
 * - TESTNET: (Optional) Set to "true" to use Sepolia; defaults to mainnet.
 * - MNEMONIC: Wallet mnemonic to sign the Ethereum transaction.
 * - HUB_POOL_ADDRESS: Ethereum address of the Hub Pool.
 * - NODE_URL_1: Ethereum RPC URL for mainnet (ignored if TESTNET=true).
 * - NODE_URL_11155111: Ethereum RPC URL for Sepolia (ignored if TESTNET=false).
 *
 * Example Usage:
 * TESTNET=true \
 * NODE_URL_11155111=$NODE_URL_11155111 \
 * MNEMONIC=$MNEMONIC \
 * HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS \
 * anchor run bridgeLiabilityToHubPool \
 * --provider.cluster "devnet" \
 * --provider.wallet $SOLANA_PKEY_PATH
 *
 * Note:
 * - Ensure all required environment variables are properly configured.
 * - Pending USDC liabilities must exist in the Solana Spoke Pool for the script to execute.
 */

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program } from "@coral-xyz/anchor";
import { ASSOCIATED_TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { PublicKey, SystemProgram } from "@solana/web3.js";
// eslint-disable-next-line camelcase
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { SvmSpoke } from "../../target/types/svm_spoke";
// eslint-disable-next-line camelcase
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  MAINNET_CCTP_MESSAGE_TRANSMITTER_ADDRESS,
  SEPOLIA_CCTP_MESSAGE_TRANSMITTER_ADDRESS,
  SOLANA_SPOKE_STATE_SEED,
  SOLANA_USDC_DEVNET,
  SOLANA_USDC_MAINNET,
} from "./utils/constants";

import { TOKEN_SYMBOLS_MAP } from "@across-protocol/constants";
import { getNodeUrl } from "@uma/common";
import { BigNumber, ethers } from "ethers";
import { TokenMessengerMinter } from "../../target/types/token_messenger_minter";
import { getMessages } from "../../test/svm/cctpHelpers";
import { BondToken__factory } from "../../typechain";
import { formatUsdc, requireEnv } from "./utils/helpers";

// Set up Solana provider.
const provider = AnchorProvider.env();
anchor.setProvider(provider);

// Get Solana programs and IDLs.
const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
const messageTransmitterIdl = require("../../target/idl/message_transmitter.json");
const tokenMessengerMinterIdl = require("../../target/idl/token_messenger_minter.json");

// CCTP domains.
const ethereumDomain = 0; // Ethereum
const solanaDomain = 5; // Solana

// Set up Ethereum provider and signer.
const nodeURL = process.env.TESTNET === "true" ? getNodeUrl("sepolia", true) : getNodeUrl("mainnet", true);
const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

// Get the HubPool contract instance.
const hubPoolAddress = ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS")); // Used to check USDC balance before and after.

const messageTransmitterAbi = [
  {
    inputs: [
      {
        internalType: "bytes",
        name: "message",
        type: "bytes",
      },
      {
        internalType: "bytes",
        name: "attestation",
        type: "bytes",
      },
    ],
    name: "receiveMessage",
    outputs: [
      {
        internalType: "bool",
        name: "success",
        type: "bool",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "",
        type: "bytes32",
      },
    ],
    name: "usedNonces",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

async function bridgeLiabilityToHubPool(): Promise<void> {
  const seed = SOLANA_SPOKE_STATE_SEED; // Seed is always 0 for the state account PDA in public networks.

  // Resolve Solana cluster, EVM chain ID, Iris API URL and USDC addresses.
  let isDevnet: boolean;
  const solanaRpcEndpoint = provider.connection.rpcEndpoint;
  if (solanaRpcEndpoint.includes("devnet")) isDevnet = true;
  else if (solanaRpcEndpoint.includes("mainnet")) isDevnet = false;
  else throw new Error(`Unsupported solanaCluster endpoint: ${solanaRpcEndpoint}`);

  const svmUsdc = isDevnet ? SOLANA_USDC_DEVNET : SOLANA_USDC_MAINNET;

  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );

  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;

  const cctpMessageTransmitter = isDevnet
    ? SEPOLIA_CCTP_MESSAGE_TRANSMITTER_ADDRESS
    : MAINNET_CCTP_MESSAGE_TRANSMITTER_ADDRESS;

  const messageTransmitter = new ethers.Contract(cctpMessageTransmitter, messageTransmitterAbi, ethersSigner);

  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  const usdcAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[evmChainId];
  const usdc = BondToken__factory.connect(usdcAddress, ethersProvider);
  const usdcBalanceBefore = await usdc.balanceOf(hubPoolAddress);

  console.log("Receiving liability from Solana Spoke Pool to Ethereum Hub Pool...");
  console.table([
    { Property: "isTestnet", Value: process.env.TESTNET === "true" },
    { Property: "hubPoolAddress", Value: hubPoolAddress },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "usdcBalanceBefore", Value: usdcBalanceBefore.toString() },
  ]);

  const [transferLiability] = PublicKey.findProgramAddressSync(
    [Buffer.from("transfer_liability"), new PublicKey(svmUsdc).toBuffer()],
    svmSpokeProgram.programId
  );

  const liability = await svmSpokeProgram.account.transferLiability.fetch(transferLiability);
  console.log(`Pending transfer liability: ${formatUsdc(BigNumber.from(liability.pendingToHubPool.toString()))} USDC.`);

  if (liability.pendingToHubPool.eq(new BN(0))) {
    console.log("No pending transfer liability to bridge. Exiting...");
    return;
  }

  console.log("Bridging liability to hub pool...");
  const txHash = await bridgeTokensToHubPool(
    liability.pendingToHubPool,
    provider.wallet as anchor.Wallet,
    statePda,
    new PublicKey(svmUsdc)
  );

  const attestationResponse = await getMessages(txHash, solanaDomain, irisApiUrl);
  const { attestation, message, eventNonce } = attestationResponse.messages[0];
  console.log("CCTP attestation response:", attestationResponse.messages[0]);

  const nonceHash = ethers.utils.solidityKeccak256(["uint32", "uint64"], [solanaDomain, eventNonce]);
  const usedNonces = await messageTransmitter.usedNonces(nonceHash);
  if (usedNonces.eq(1)) {
    console.log(`Skipping already received message. Exiting...`);
    return;
  }

  console.log("Receiving message from CCTP...");
  const receiveTx = await messageTransmitter.receiveMessage(message, attestation);
  console.log(`Tx hash: ${receiveTx.hash}`);
  await receiveTx.wait();
  console.log(`Received message`);

  const usdcBalanceAfter = await usdc.balanceOf(hubPoolAddress);
  console.log(
    `Hub Pool USDC balance after: ${formatUsdc(usdcBalanceAfter)}. Received ${formatUsdc(
      usdcBalanceAfter.sub(usdcBalanceBefore)
    )} USDC.`
  );
  console.log("✅ Bridge liability to hub pool completed successfully.");
}

async function bridgeTokensToHubPool(amount: BN, signer: anchor.Wallet, statePda: PublicKey, inputToken: PublicKey) {
  const messageTransmitterProgram = new Program<MessageTransmitter>(messageTransmitterIdl, provider);

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
    svmSpokeProgram.programId
  );
  const tokenMessengerMinterProgram = new Program<TokenMessengerMinter>(tokenMessengerMinterIdl, provider);

  const [tokenMessengerMinterSenderAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("sender_authority")],
    tokenMessengerMinterProgram.programId
  );

  const [messageTransmitter] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter")],
    messageTransmitterProgram.programId
  );

  const [tokenMessenger] = PublicKey.findProgramAddressSync(
    [Buffer.from("token_messenger")],
    tokenMessengerMinterProgram.programId
  );

  const [remoteTokenMessenger] = PublicKey.findProgramAddressSync(
    [Buffer.from("remote_token_messenger"), Buffer.from(anchor.utils.bytes.utf8.encode(ethereumDomain.toString()))],
    tokenMessengerMinterProgram.programId
  );

  const [tokenMinter] = PublicKey.findProgramAddressSync(
    [Buffer.from("token_minter")],
    tokenMessengerMinterProgram.programId
  );

  const [localToken] = PublicKey.findProgramAddressSync(
    [Buffer.from("local_token"), inputToken.toBuffer()],
    tokenMessengerMinterProgram.programId
  );

  const [cctpEventAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("__event_authority")],
    tokenMessengerMinterProgram.programId
  );

  const messageSentEventData = anchor.web3.Keypair.generate(); // This will hold the message sent event data.
  const bridgeTokensToHubPoolAccounts = {
    payer: signer.publicKey,
    mint: inputToken,
    state: statePda,
    transferLiability,
    vault,
    tokenMessengerMinterSenderAuthority,
    messageTransmitter,
    tokenMessenger,
    remoteTokenMessenger,
    tokenMinter,
    localToken,
    messageSentEventData: messageSentEventData.publicKey,
    messageTransmitterProgram: messageTransmitterProgram.programId,
    tokenMessengerMinterProgram: tokenMessengerMinterProgram.programId,
    tokenProgram: TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
    cctpEventAuthority: cctpEventAuthority,
    program: svmSpokeProgram.programId,
  };

  const initialVaultBalance = (await provider.connection.getTokenAccountBalance(vault)).value.amount;

  const tx = await svmSpokeProgram.methods
    .bridgeTokensToHubPool(new BN(amount))
    .accounts(bridgeTokensToHubPoolAccounts)
    .signers([messageSentEventData])
    .rpc();

  const finalVaultBalance = (await provider.connection.getTokenAccountBalance(vault)).value.amount;

  console.log(`SVM Spoke Pool Initial Vault balance: ${formatUsdc(BigNumber.from(initialVaultBalance))} USDC.`);
  console.log(`SVM Spoke Pool Final Vault balance: ${formatUsdc(BigNumber.from(finalVaultBalance))} USDC.`);
  console.log(
    `Sent ${formatUsdc(BigNumber.from(initialVaultBalance).sub(BigNumber.from(finalVaultBalance)))} USDC through CCTP.`
  );

  return tx;
}

// Run the bridgeLiabilityToHubPool function
bridgeLiabilityToHubPool();
