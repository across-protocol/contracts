import { getContractFactory, ethers, SignerWithAddress } from "../utils/utils";
import { hre } from "../utils/utils.hre";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP, CIRCLE_DOMAIN_IDs } from "../deploy/consts";
import { getNodeUrl } from "@uma/common";
import { Event, Wallet, providers } from "ethers";
import fetch from "node-fetch";

const MAX_L1_BLOCK_LOOKBACK = 1000;
const MAX_L2_BLOCK_LOOKBACK = 1000;

const chainToArtifactPrefix: Record<number, string> = {
  1: "Ethereum",
  5: "Ethereum",
  10: "Optimism",
  420: "Optimism",
  42161: "Arbitrum",
  421613: "Arbitrum",
  8453: "Base",
  84531: "Base",
  137: "Polygon",
  80001: "Polygon",
};

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

/**
 * Script to claim L1->L2 or L2->L1 messages. Run via
 * ```
 * RECEIVE_MESSAGES_ON=l1 \
 * yarn hardhat run ./scripts/claimLineaMessages.ts \
 * --network linea-goerli \
 * ```
 * Environment variables:
 * - `RECEIVE_MESSAGES_ON`: Which messages to claim. Either `l1` or `l2`.
 * Flags:
 * - `--network`: The L2 network, i.e. `linea-goerli` or `linea`.
 *
 */
async function main() {
  const receiveMessagesOn = process.env.RECEIVE_MESSAGES_ON || "l2";
  const l1BlockLookback = parseInt(process.env.BLOCK_LOOKBACK || "8640");
  const l2BlockLookback = parseInt(process.env.BLOCK_LOOKBACK || "17380");

  const l1ChainId = parseInt(await hre.companionNetworks.l1.getChainId());
  const l2ChainId = parseInt(await hre.getChainId());
  const l1Provider = new ethers.providers.JsonRpcProvider(
    getNodeUrl(l1ChainId === 1 ? "mainnet" : "goerli", true, l1ChainId)
  );
  const l2Provider = ethers.provider;
  const l1Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l1Provider);
  const [l2Signer] = await ethers.getSigners();

  console.log("\nL1 chain ID:", l1ChainId);
  console.log("L2 chain ID:", l2ChainId);
  console.log("Signer address:", l1Signer.address);

  // Get relevant src events
  const srcEvents =
    receiveMessagesOn === "l1"
      ? await getL2SrcEvents(l2ChainId, l2Provider, l2Signer, l2BlockLookback)
      : await getL1SrcEvents(l1ChainId, l1Provider, l1Signer, l1BlockLookback);

  // Get relevant message hashes and bytes
  const uniqueTxHashes = new Set(srcEvents.map((event) => event.transactionHash));
  const messageHashesAndBytes = await parseMessageHashesAndBytes(
    Array.from(uniqueTxHashes),
    receiveMessagesOn === "l1" ? l2Provider : l1Provider
  );
  const relevantMessageHashesAndBytes = messageHashesAndBytes.filter(
    (messageHashAndBytes) =>
      messageHashAndBytes.destinationDomain === CIRCLE_DOMAIN_IDs[receiveMessagesOn === "l1" ? l1ChainId : l2ChainId]
  );
  console.log(`\nParsed ${relevantMessageHashesAndBytes.length} relevant 'MessageSent' events`);

  if (relevantMessageHashesAndBytes.length === 0) {
    console.log("No relevant messages to receive");
    return;
  }

  // Request attestations
  console.log("\nRequesting attestations...");
  const attestations = [];
  for (const messageHashAndBytes of relevantMessageHashesAndBytes) {
    const attestation = await requestAttestation(messageHashAndBytes.messageHash);
    attestations.push(attestation);
  }

  // Receive messages
  const messageTransmitter = new ethers.Contract(
    receiveMessagesOn === "l1"
      ? L1_ADDRESS_MAP[l1ChainId].cctpMessageTransmitter
      : L2_ADDRESS_MAP[l2ChainId].cctpMessageTransmitter,
    messageTransmitterAbi,
    receiveMessagesOn === "l1" ? l1Signer : l2Signer
  );

  console.log(`\nReceiving messages on ${receiveMessagesOn.toUpperCase()}`, {
    messageTransmitter: messageTransmitter.address,
    chainId: receiveMessagesOn === "l1" ? l1ChainId : l2ChainId,
  });
  for (const [i, messageHashAndBytes] of relevantMessageHashesAndBytes.entries()) {
    const attestation = attestations[i];
    const { messageBytes, messageHash, nonceHash } = messageHashAndBytes;
    console.log(`Receiving message ${messageHash}...`);

    try {
      // Skip message if already received
      const usedNonces = await messageTransmitter.usedNonces(nonceHash);
      if (usedNonces.eq(1)) {
        console.log(`Skipping already received message.`);
        continue;
      }

      const receiveTx = await messageTransmitter.receiveMessage(messageBytes, attestation);
      console.log(`Tx hash: ${receiveTx.hash}`);
      await receiveTx.wait();
      console.log(`Received message`);
    } catch (error) {
      console.log(`Failed to receive`, error);
      continue;
    }
  }
}

async function requestAttestation(messageHash: string) {
  console.log(`Attesting message hash: ${messageHash}`);
  let attestationResponse = { status: "pending", attestation: "" };
  while (attestationResponse.status !== "complete") {
    const response = await fetch(`https://iris-api-sandbox.circle.com/attestations/${messageHash}`);
    attestationResponse = await response.json();
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  console.log("Attested");
  return attestationResponse.attestation;
}

async function parseMessageHashesAndBytes(txHashes: string[], srcProvider: providers.JsonRpcProvider) {
  const transactionReceipts = await Promise.all(txHashes.map((txHash) => srcProvider.getTransactionReceipt(txHash)));
  const messageHashesAndBytes = [];
  for (const transactionReceipt of transactionReceipts) {
    const eventTopic = ethers.utils.id("MessageSent(bytes)");
    const log = transactionReceipt.logs.find((l) => l.topics[0] === eventTopic);
    if (!log) {
      continue;
    }
    const messageBytes = ethers.utils.defaultAbiCoder.decode(["bytes"], log.data)[0];
    const messageBytesArray = ethers.utils.arrayify(messageBytes);
    const sourceDomain = ethers.utils.hexlify(messageBytesArray.slice(4, 8)); // sourceDomain 4 bytes starting index 4
    const destinationDomain = ethers.utils.hexlify(messageBytesArray.slice(8, 12)); // destinationDomain 4 bytes starting index 8
    const nonce = ethers.utils.hexlify(messageBytesArray.slice(12, 20)); // nonce 8 bytes starting index 12
    const nonceHash = ethers.utils.solidityKeccak256(["uint32", "uint64"], [sourceDomain, nonce]);
    const messageHash = ethers.utils.keccak256(messageBytes);
    messageHashesAndBytes.push({
      messageHash,
      messageBytes,
      nonceHash,
      destinationDomain: parseInt(destinationDomain),
    });
  }
  return messageHashesAndBytes;
}

async function getL1SrcEvents(
  l1ChainId: number,
  l1Provider: providers.JsonRpcProvider,
  l1Signer: Wallet,
  blockLookback: number,
  maxBlockLookback = MAX_L1_BLOCK_LOOKBACK
) {
  const l1LatestBlock = await l1Provider.getBlockNumber();

  const hubPoolDeployment = await hre.companionNetworks.l1.deployments.get("HubPool");
  const adapter = (
    await getContractFactory(`${chainToArtifactPrefix[l1ChainId]}_Adapter`, { signer: l1Signer })
  ).attach(hubPoolDeployment.address);

  console.log("\nQuerying L1 src events...", {
    hubPool: hubPoolDeployment.address,
    l1ChainId,
  });

  return getSrcEvents(
    l1LatestBlock,
    blockLookback,
    async (fromBlock: number, toBlock: number) => {
      console.log(`Querying blocks ${fromBlock} - ${toBlock}...`);
      const tokensRelayedEvents = await adapter.queryFilter("TokensRelayed", fromBlock, toBlock);
      const usdcRelayedEvents = tokensRelayedEvents.filter(
        (event) => event.args?.l1Token === L1_ADDRESS_MAP[l1ChainId].l1UsdcAddress
      );
      console.log(`${usdcRelayedEvents.length} 'TokensRelayed'`);
      return usdcRelayedEvents;
    },
    maxBlockLookback
  );
}

async function getL2SrcEvents(
  l2ChainId: number,
  l2Provider: providers.JsonRpcProvider,
  l2Signer: SignerWithAddress,
  blockLookback: number,
  maxBlockLookback = MAX_L2_BLOCK_LOOKBACK
) {
  const l2LatestBlock = await l2Provider.getBlockNumber();

  const spokePoolArtifactPrefix = chainToArtifactPrefix[l2ChainId];
  const spokePoolArtifactName = `${spokePoolArtifactPrefix}_SpokePool`;
  const spokePoolEventName = `${
    spokePoolArtifactPrefix === "Base" ? "Optimism" : spokePoolArtifactPrefix
  }TokensBridged`;
  const spokePoolDeployment = await hre.deployments.get(spokePoolArtifactName);
  const spokePool = (await getContractFactory(spokePoolArtifactName, { signer: l2Signer })).attach(
    spokePoolDeployment.address
  );

  console.log("\nQuerying L2 src events...", {
    spokePool: spokePool.address,
    l2ChainId,
  });

  return getSrcEvents(
    l2LatestBlock,
    blockLookback,
    async (fromBlock: number, toBlock: number) => {
      console.log(`Querying blocks ${fromBlock} - ${toBlock}...`);
      const tokensBridgedEvents = await spokePool.queryFilter(spokePoolEventName, fromBlock, toBlock);
      console.log(`${tokensBridgedEvents.length} '${spokePoolEventName}'`);
      return tokensBridgedEvents;
    },
    maxBlockLookback
  );
}

async function getSrcEvents(
  latestBlock: number,
  blockLookback: number,
  queryFn: (fromBlock: number, toBlock: number) => Promise<Event[]>,
  maxBlockLookback: number
) {
  const initialFromBlock = latestBlock - blockLookback;
  let fromBlock = initialFromBlock;

  const relevantSrcEvents = [];

  while (fromBlock < latestBlock) {
    const numBlocks = Math.max(latestBlock - fromBlock, 0);

    if (numBlocks === 0) {
      break;
    }

    const toBlock = numBlocks > maxBlockLookback ? fromBlock + maxBlockLookback : fromBlock + numBlocks;
    const events = await queryFn(fromBlock, toBlock);
    relevantSrcEvents.push(...events);

    fromBlock = toBlock + 1;
  }
  return relevantSrcEvents;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
