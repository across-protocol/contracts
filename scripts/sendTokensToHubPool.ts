import { getContractFactory, ethers, SignerWithAddress } from "../utils/utils";
import { TOKEN_SYMBOLS_MAP, CHAIN_IDs } from "@across-protocol/constants";
import { hre } from "../utils/utils.hre";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "../deploy/consts";
import { getNodeUrl, EMPTY_MERKLE_ROOT } from "@uma/common";
import { Event, Wallet, providers, Contract } from "ethers";

/**
 * Script to claim L1->L2 or L2->L1 messages. Run via
 * ```
 * yarn hardhat run ./scripts/sendTokensToHubPool.ts \
 * --network base \
 * ```
 * This REQUIRES a spoke pool to be deployed to the specified network AND for the
 * spoke pool to have the signer as the `crossDomainAdmin`.
 * Flags:
 * - `--network`: The L2 network, which is defined in hardhat.config.ts.
 */

async function main() {
  /*
   * Setup: Need to obtain all contract addresses involved and instantiate L1/L2 providers and contracts.
   */

  // Instantiate providers/signers/chainIds
  const l2ChainId = parseInt(await hre.getChainId());
  const l1ChainId = parseInt(await hre.companionNetworks.l1.getChainId());

  // TODO: Figure out how to get this from hardhat.config.ts
  const l2ProviderUrl =
    process.env[`NODE_URL_${l2ChainId}`] ?? `https://base-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`;
  const l1ProviderUrl =
    process.env[`NODE_URL_${l1ChainId}`] ?? `https://base-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`;

  const l2Provider = new ethers.providers.JsonRpcProvider(l2ProviderUrl);
  const l2Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l2Provider);
  const l1Provider = new ethers.providers.JsonRpcProvider(l1ProviderUrl);
  const l1Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l1Provider);

  // Process environment first so we can throw errors immediately if we are missing any configuration.
  // TODO: I need to figure out a way to get this dynamically.
  const rootBundleId = process.env.TEST_ROOT_BUNDLE_ID ?? 0;
  const spokeAddress = process.env.TEST_SPOKE_POOL_ADDRESS; // We need to specify this since this is an unsaved deployment.
  // TODO: It would be nice to fetch these dynamically based off of the chain ids.
  if (!spokeAddress) {
    throw new Error(
      "[-] No spoke pool address specified. Please set TEST_SPOKE_POOL_ADDRESS to the target L2 spoke pool address"
    );
  }
  const adapterAddress = process.env.ADAPTER_ADDRESS;
  if (!adapterAddress) {
    throw new Error("[-] No adapter address specified. Please set ADAPTER_ADDRESS to the Across L1 adapter address");
  }
  const tokenAddress = process.env.TEST_TOKEN_ADDRESS ?? TOKEN_SYMBOLS_MAP.WETH.addresses[l2ChainId];
  if (!tokenAddress) {
    throw new Error(
      "[-] No token address specified and cannot default to WETH. Please set TEST_TOKEN_ADDRESS to the l2 token address to send back to the hub pool"
    );
  }
  const amountToReturn = process.env.AMOUNT_TO_RETURN ?? 1000; // Default to dust.

  // Construct the contracts
  const spokePool = new Contract(spokeAddress, spokePoolAbi, l2Signer);
  const adapter = new Contract(adapterAddress, adapterAbi, l1Signer);

  console.log("[+] Successfully constructed all contracts. Beginning L1 message relay.");
  /*
   * Step 1: Craft and send a message to be sent to the provided L1 chain adapter contract. This message should be used to call `relayRootBundle` on the
   * associated L2 contract
   */
  const rootBundleType = "tuple(uint256,uint256,uint256[],uint32,address,address[])";
  // Construct the root bundle
  const encodedRootBundle = ethers.utils.defaultAbiCoder.encode(
    [rootBundleType],
    [[amountToReturn, l2ChainId, [], 0, tokenAddress, []]]
  );
  const rootBundleHash = ethers.utils.keccak256(encodedRootBundle);
  // Submit the root bundle to chain.
  const relayRootBundleTxnData = spokePool.interface.encodeFunctionData("relayRootBundle", [
    rootBundleHash,
    EMPTY_MERKLE_ROOT,
  ]);
  const adapterTxn = await adapter.relayMessage(spokePool.address, relayRootBundleTxnData);
  const hash = await adapterTxn;
  // TODO: Specify adapter name
  console.log(
    `[+] Called L1 adapter to relay refund leaf message to mock spoke pool at ${
      spokePool.address
    }. Txn: ${JSON.stringify(hash)}`
  );
  /*
   * Step 2: Spin until we observe the message to be executed on the L2. This should take ~3 minutes.
   */
  const threeMins = 1000 * 60 * 3;
  await delay(threeMins);

  // We should be able to query the canonical messenger to see if our L1 message was propagated, but this requires us to instantiate a unique L2 messenger contract
  // for each new chain we make, which is not scalable. Instead, we query whether our root bundle is in the spoke pool contract, as this is generalizable and does not
  // require us to instantiate any new contract.
  while (1) {
    try {
      // Check the root bundle
      await spokePool.rootBundles(rootBundleId);
      break;
    } catch (e) {
      // No root bundle made it yet. Continue to spin
      console.log("[-] Root bundle not found on L2. Waiting another 30 seconds.");
    }
  }
  console.log("[+] Root bundle observed on L2 spoke pool. Attempting to execute.");
  /*
   * Step 3: Call `executeRelayerRefund` on the target spoke pool to send funds back to the hub pool (or, whatever was initialized as the `hubPool` in the deploy
   * script, which is likely the dev EOA).
   */
  const executeRelayerRefundLeaf = await spokePool.executeRelayerRefundLeaf(
    rootBundleId,
    [amountToReturn, l2ChainId, [], 0, tokenAddress, []],
    []
  );
  console.log(
    `[+] Executed root bundle with transaction hash ${executeRelayerRefundLeaf}. You can now test the finalizer in the relayer repository.`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

// Sleep
function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/////////////////////
/// Contract ABIs ///
/////////////////////
// We only need to call two functions in this script: one to set a root bundle, and one to execute that set root bundle.
// This ABI should be consistent for all spoke pool implementations.
const spokePoolAbi = [
  {
    inputs: [
      {
        internalType: "uint32",
        name: "rootBundleId",
        type: "uint32",
      },
      {
        components: [
          {
            internalType: "uint256",
            name: "amountToReturn",
            type: "uint256",
          },
          {
            internalType: "uint256",
            name: "chainId",
            type: "uint256",
          },
          {
            internalType: "uint256[]",
            name: "refundAmounts",
            type: "uint256[]",
          },
          {
            internalType: "uint32",
            name: "leafId",
            type: "uint32",
          },
          {
            internalType: "address",
            name: "l2TokenAddress",
            type: "address",
          },
          {
            internalType: "address[]",
            name: "refundAddresses",
            type: "address[]",
          },
        ],
        internalType: "struct SpokePoolInterface.RelayerRefundLeaf",
        name: "relayerRefundLeaf",
        type: "tuple",
      },
      {
        internalType: "bytes32[]",
        name: "proof",
        type: "bytes32[]",
      },
    ],
    name: "executeRelayerRefundLeaf",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "relayerRefundRoot",
        type: "bytes32",
      },
      {
        internalType: "bytes32",
        name: "slowRelayRoot",
        type: "bytes32",
      },
    ],
    name: "relayRootBundle",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    name: "rootBundles",
    outputs: [
      {
        internalType: "bytes32",
        name: "slowRelayRoot",
        type: "bytes32",
      },
      {
        internalType: "bytes32",
        name: "relayerRefundRoot",
        type: "bytes32",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

// Only one function needs to be called in the adapter.
const adapterAbi = [
  {
    inputs: [
      {
        internalType: "address",
        name: "target",
        type: "address",
      },
      {
        internalType: "bytes",
        name: "message",
        type: "bytes",
      },
    ],
    name: "relayMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];
