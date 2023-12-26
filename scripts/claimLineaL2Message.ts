import { getContractFactory, ethers } from "../utils/utils";
import { hre } from "../utils/utils.hre";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "../deploy/consts";
import { getNodeUrl } from "@uma/common";
import { LineaSDK, OnChainMessageStatus } from "@consensys/linea-sdk";

const MAX_L1_BLOCK_LOOKBACK = 1000;

/**
 * Script to claim L1->L2 messages sent by Linea_Adapter. Run via
 * ```
 * yarn hardhat run ./scripts/claimLineaL2Message.ts --network linea-goerli
 * ```
 */
async function main() {
  const blockLookback = parseInt(process.env.BLOCK_LOOKBACK || "8640");

  const l2ChainId = parseInt(await hre.getChainId());
  const l1ChainId = parseInt(await hre.companionNetworks.l1.getChainId());
  const l1Provider = new ethers.providers.JsonRpcProvider(
    getNodeUrl(l1ChainId === 1 ? "mainnet" : "goerli", true, l1ChainId)
  );
  const l1Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l1Provider);

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

  const hubPoolDeployment = await hre.companionNetworks.l1.deployments.get("HubPool");
  const lineaAdapter = (await getContractFactory("Linea_Adapter", { signer: l1Signer })).attach(
    hubPoolDeployment.address
  );

  console.log("\nL1 chain ID:", l1ChainId);
  console.log("L2 chain ID:", l2ChainId);
  console.log("Signer address:", l1Signer.address);

  console.log("\nQuerying 'MessageRelayed' or 'TokensRelayed' events from HubPool:", lineaAdapter.address);

  const l1LatestBlock = await l1Provider.getBlockNumber();
  const l1InitialFromBlock = l1LatestBlock - blockLookback;
  let l1FromBlock = l1InitialFromBlock;

  const relevantMessageSentEvents = [];

  while (l1FromBlock < l1LatestBlock) {
    const numBlocks = Math.max(l1LatestBlock - l1FromBlock, 0);

    if (numBlocks === 0) {
      break;
    }

    const toBlock = numBlocks > MAX_L1_BLOCK_LOOKBACK ? l1FromBlock + MAX_L1_BLOCK_LOOKBACK : l1FromBlock + numBlocks;
    console.log(`Querying blocks ${l1FromBlock} - ${toBlock}...`);
    const [tokensRelayedEvents, messageRelayedEvent] = await Promise.all([
      lineaAdapter.queryFilter("TokensRelayed", l1FromBlock, toBlock),
      lineaAdapter.queryFilter("MessageRelayed", l1FromBlock, toBlock),
    ]);
    const events = [...tokensRelayedEvents, ...messageRelayedEvent];
    console.log(
      `Found ${events.length} events: ${tokensRelayedEvents.length} 'TokensRelayed', ${messageRelayedEvent.length} 'MessageRelayed'`
    );

    const uniqueTxHashes = new Set(events.map((event) => event.transactionHash));
    for (const txHash of uniqueTxHashes) {
      const messageSentEvents = await l1MessageService.getMessagesByTransactionHash(txHash);
      if (messageSentEvents && messageSentEvents.length > 0) {
        relevantMessageSentEvents.push(...messageSentEvents);
      }
    }

    l1FromBlock = toBlock + 1;
  }

  console.log(
    `\nParsed ${relevantMessageSentEvents.length} 'MessageSent' events in blocks ${l1InitialFromBlock} - ${l1LatestBlock}`
  );

  console.log("\nCheck status and claim via L2 MessageService:", l2MessageService.contractAddress);
  for (const messageSentEvent of relevantMessageSentEvents) {
    const messageStatus = await l2MessageService.getMessageStatus(messageSentEvent.messageHash);

    if (messageStatus === OnChainMessageStatus.CLAIMED) {
      console.log("Skipping already claimed message:", messageSentEvent.messageHash);
      continue;
    }

    if (messageStatus === OnChainMessageStatus.UNKNOWN) {
      console.log("Skipping not received message:", messageSentEvent.messageHash);
      continue;
    }

    try {
      console.log("Claiming message:", messageSentEvent.messageHash);
      const fees = await l2MessageService.get1559Fees();
      const limit = await l2MessageService.estimateClaimGas(messageSentEvent, { ...fees });
      const claimTx = await l2MessageService.claim(
        { ...messageSentEvent, feeRecipient: l1Signer.address },
        {
          ...fees,
          gasLimit: limit.mul(2),
        }
      );
      console.log("Tx hash:", claimTx.hash);
      await claimTx.wait();
      console.log("Successfully claimed message:", messageSentEvent.messageHash);
    } catch (error) {
      console.log("Failed to claim:", error);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
