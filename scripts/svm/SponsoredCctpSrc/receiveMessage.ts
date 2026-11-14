// This script finalizes the message on the SponsoredCCTPDstPeriphery contract.

import { PUBLIC_NETWORKS } from "@across-protocol/constants";
import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  decodeMessageSentDataV2,
  getMessageTransmitterV2Program,
  getSponsoredCctpSrcPeripheryProgram,
  getV2BurnAttestation,
  isSolanaDevnet,
  processEventFromTx,
  publicKeyToEvmAddress,
} from "../../../src/svm/web3-v1";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { requireEnv } from "../utils/helpers";

// Set up Solana provider and programs
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const messageTransmitterV2Program = getMessageTransmitterV2Program(provider);

const irisApiUrl = isSolanaDevnet(provider) ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;

// Set up Ethereum provider and signer.
const nodeURL = requireEnv("NODE_URL");
const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

const sponsoredCCTPDstPeripheryIface = new ethers.utils.Interface([
  "function receiveMessage(bytes message, bytes attestation, bytes signature)",
]);

// Parse arguments
const argvPromise = yargs(hideBin(process.argv)).option("txSignature", {
  type: "string",
  demandOption: true,
  describe: "Transaction signature of the deposit to finalize",
}).argv;

async function getDeposits(txSignature: string): Promise<{ quoteSignature: Buffer; sourceMessageData: Buffer }[]> {
  const txResult = await provider.connection.getTransaction(txSignature, {
    commitment: "confirmed",
    maxSupportedTransactionVersion: 0,
  });
  if (!txResult) {
    throw new Error(`Transaction ${txSignature} not found`);
  }
  if (!!txResult.meta?.err) {
    throw new Error(`Transaction ${txSignature} failed: ${txResult.meta.err}`);
  }

  const events = processEventFromTx(txResult, [program]);

  const deposits: { quoteSignature: Buffer; sourceMessageData: Buffer }[] = [];
  for (const [index, event] of events.entries()) {
    if (event.name === "sponsoredDepositForBurn") {
      const quoteSignature: Buffer = event.data.signature;

      const nextIndex = index + 1;
      if (events.length < nextIndex || events[nextIndex].name !== "createdEventAccount") {
        throw new Error("Unexpected event sequence: expected 'createdEventAccount' after 'sponsoredDepositForBurn'");
      }
      const messageSentEventData: PublicKey = events[nextIndex].data.messageSentEventData;
      const messageSentAccount = await provider.connection.getAccountInfo(messageSentEventData);
      if (!messageSentAccount) {
        console.log(`MessageSent account ${messageSentEventData.toString()} does not exist, skipping.`);
        continue;
      }
      const sourceMessageData = (await messageTransmitterV2Program.account.messageSent.fetch(messageSentEventData))
        .message;

      deposits.push({ quoteSignature, sourceMessageData });
    }
  }

  if (deposits.length === 0) {
    throw new Error("No sponsored deposit events found in the transaction");
  }
  return deposits;
}
async function receiveMessage(): Promise<void> {
  const argv = await argvPromise;
  const txSignature = argv.txSignature;

  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  const evmCctpDomain = PUBLIC_NETWORKS[evmChainId].cctpDomain;

  const deposits = await getDeposits(txSignature);
  for (const deposit of deposits) {
    const attestationResponse = await getV2BurnAttestation(txSignature, deposit.sourceMessageData, irisApiUrl);
    if (!attestationResponse) {
      console.log(`No matching attestation found for deposit in tx ${txSignature}, skipping.`);
      continue;
    }
    const sourceMessage = decodeMessageSentDataV2(deposit.sourceMessageData);
    const sponsoredCCTPDstPeripheryAddress = publicKeyToEvmAddress(sourceMessage.destinationCaller);
    if (sourceMessage.destinationDomain !== evmCctpDomain) {
      console.log(
        `Skipping deposit with destination domain ${sourceMessage.destinationDomain} not matching EVM CCTP domain ${evmCctpDomain}`
      );
      continue;
    }

    const destinationCallerCode = await ethersProvider.getCode(sponsoredCCTPDstPeripheryAddress);
    if (destinationCallerCode === "0x") {
      console.log(`Skipping deposit as destination caller ${sponsoredCCTPDstPeripheryAddress} is not a contract`);
      continue;
    }

    const sponsoredCCTPDstPeriphery = new ethers.Contract(
      sponsoredCCTPDstPeripheryAddress,
      sponsoredCCTPDstPeripheryIface,
      ethersSigner
    );

    console.log("Trying to finalize sponsored deposit with the following parameters:");
    console.log(`- source tx signature: ${txSignature}`);
    console.log(`- destination contract: ${sponsoredCCTPDstPeripheryAddress}`);
    console.log(`- destination message: ${attestationResponse.destinationMessage.toString("hex")}`);
    console.log(`- attestation: ${attestationResponse.attestation.toString("hex")}`);
    console.log(`- quote signature: 0x${deposit.quoteSignature.toString("hex")}`);

    try {
      const tx = await sponsoredCCTPDstPeriphery.receiveMessage(
        attestationResponse.destinationMessage,
        attestationResponse.attestation,
        deposit.quoteSignature
      );
      console.log(`\nTransaction sent successfully, transaction hash: ${tx.hash}, waiting for confirmation...`);
      const receipt = await tx.wait();
      console.log(`- Transaction confirmed in block ${receipt.blockNumber}`);
    } catch (error) {
      console.error(`\nError finalizing sponsored deposit: ${error}`);
      continue;
    }
  }
}

receiveMessage();
