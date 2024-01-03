import { getContractFactory, ethers, SignerWithAddress } from "../utils/utils";
import { hre } from "../utils/utils.hre";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "../deploy/consts";
import { getNodeUrl } from "@uma/common";
import { LineaSDK, OnChainMessageStatus } from "@consensys/linea-sdk";
import { Event, Wallet, providers } from "ethers";

const MAX_L1_BLOCK_LOOKBACK = 1000;
const MAX_L2_BLOCK_LOOKBACK = 1000;

/**
 * Script to claim L1->L2 or L2->L1 messages. Run via
 * ```
 * CLAIM_MESSAGES_ON=l1 \
 * yarn hardhat run ./scripts/claimLineaMessages.ts \
 * --network linea-goerli \
 * ```
 * Environment variables:
 * - `CLAIM_MESSAGES_ON`: Which messages to claim. Either `l1` or `l2`.
 * Flags:
 * - `--network`: The L2 network, i.e. `linea-goerli` or `linea`.
 *
 */
async function main() {
  const claimMessagesOn = process.env.CLAIM_MESSAGES_ON || "l2";
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

  const sdk = new LineaSDK({
    l1RpcUrl: getNodeUrl(l1ChainId === 1 ? "mainnet" : "goerli", true, l1ChainId),
    l2RpcUrl: `https://${l2ChainId === 59144 ? "linea" : "linea-goerli"}.infura.io/v3/${process.env.INFURA_API_KEY}`,
    l1SignerPrivateKey: l1Signer.privateKey,
    l2SignerPrivateKey: l1Signer.privateKey,
    network: l1ChainId === 1 ? "linea-mainnet" : "linea-goerli",
    mode: "read-write",
  });
  const l1MessageService = sdk.getL1Contract(L1_ADDRESS_MAP[l1ChainId].lineaMessageService);
  const l2MessageService = sdk.getL2Contract(L2_ADDRESS_MAP[l2ChainId].lineaMessageService);
  const srcMessageService = claimMessagesOn === "l1" ? l2MessageService : l1MessageService;
  const dstMessageService = claimMessagesOn === "l1" ? l1MessageService : l2MessageService;

  // Get relevant src events
  const srcEvents =
    claimMessagesOn === "l1"
      ? await getL2SrcEvents(l2Provider, l2Signer, l2BlockLookback)
      : await getL1SrcEvents(l1Provider, l1Signer, l1BlockLookback);

  // Get relevant message sent events via sdk
  const relevantMessageSentEvents = [];
  const uniqueTxHashes = new Set(srcEvents.map((event) => event.transactionHash));
  for (const txHash of uniqueTxHashes) {
    const messageSentEvents = await srcMessageService.getMessagesByTransactionHash(txHash);
    if (messageSentEvents && messageSentEvents.length > 0) {
      relevantMessageSentEvents.push(...messageSentEvents);
    }
  }
  console.log(`\nParsed ${relevantMessageSentEvents.length} 'MessageSent' events`);

  if (relevantMessageSentEvents.length === 0) {
    console.log("No relevant messages to claim");
    return;
  }

  console.log(
    `\nCheck status and claim via ${claimMessagesOn.toUpperCase()} MessageService:`,
    dstMessageService.contractAddress
  );
  for (const messageSentEvent of relevantMessageSentEvents) {
    console.log("Checking message", messageSentEvent.messageHash);
    let messageStatus = await dstMessageService.getMessageStatus(messageSentEvent.messageHash);

    // Wait for message to be received
    while (messageStatus === OnChainMessageStatus.UNKNOWN) {
      await new Promise((resolve) => setTimeout(resolve, 10_000));
      messageStatus = await dstMessageService.getMessageStatus(messageSentEvent.messageHash);
    }

    if (messageStatus === OnChainMessageStatus.CLAIMED) {
      console.log("Skipping already claimed message:", messageSentEvent.messageHash);
      continue;
    }

    try {
      console.log("Claiming message:", messageSentEvent.messageHash);
      const fees = await dstMessageService.get1559Fees();
      const limit = await dstMessageService.estimateClaimGas(messageSentEvent, { ...fees });
      const claimTx = await dstMessageService.claim(
        { ...messageSentEvent, feeRecipient: l1Signer.address },
        {
          ...fees,
          gasLimit: limit.mul(2),
        }
      );
      console.log("Tx hash:", claimTx.hash);
      await claimTx.wait();
      console.log("Successfully claimed", messageSentEvent.messageHash);
    } catch (error) {
      console.log("Failed to claim", error);
    }
  }
}

async function getL1SrcEvents(
  l1Provider: providers.JsonRpcProvider,
  l1Signer: Wallet,
  blockLookback: number,
  maxBlockLookback = MAX_L1_BLOCK_LOOKBACK
) {
  const l1LatestBlock = await l1Provider.getBlockNumber();

  const hubPoolDeployment = await hre.companionNetworks.l1.deployments.get("HubPool");
  const lineaAdapter = (await getContractFactory("Linea_Adapter", { signer: l1Signer })).attach(
    hubPoolDeployment.address
  );

  console.log("\nQuerying L1 src events from HubPool:", hubPoolDeployment.address);

  return getSrcEvents(
    l1LatestBlock,
    blockLookback,
    async (fromBlock: number, toBlock: number) => {
      console.log(`Querying blocks ${fromBlock} - ${toBlock}...`);
      const [tokensRelayedEvents, messageRelayedEvents] = await Promise.all([
        lineaAdapter.queryFilter("TokensRelayed", fromBlock, toBlock),
        lineaAdapter.queryFilter("MessageRelayed", fromBlock, toBlock),
      ]);
      console.log(`${tokensRelayedEvents.length} 'TokensRelayed', ${messageRelayedEvents.length} 'MessageRelayed'`);
      return [...tokensRelayedEvents, ...messageRelayedEvents];
    },
    maxBlockLookback
  );
}

async function getL2SrcEvents(
  l2Provider: providers.JsonRpcProvider,
  l2Signer: SignerWithAddress,
  blockLookback: number,
  maxBlockLookback = MAX_L2_BLOCK_LOOKBACK
) {
  const l2LatestBlock = await l2Provider.getBlockNumber();

  const spokePoolDeployment = await hre.deployments.get("Linea_SpokePool");
  const spokePool = (await getContractFactory("Linea_SpokePool", { signer: l2Signer })).attach(
    spokePoolDeployment.address
  );

  console.log("\nQuerying L2 src events from SpokePool:", spokePool.address);

  return getSrcEvents(
    l2LatestBlock,
    blockLookback,
    async (fromBlock: number, toBlock: number) => {
      console.log(`Querying blocks ${fromBlock} - ${toBlock}...`);
      const lineaTokensBridgedEvents = await spokePool.queryFilter("LineaTokensBridged", fromBlock, toBlock);
      console.log(`${lineaTokensBridgedEvents.length} 'LineaTokensBridged'`);
      return lineaTokensBridgedEvents;
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
