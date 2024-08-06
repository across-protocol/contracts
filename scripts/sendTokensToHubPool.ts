import { getContractFactory, ethers, SignerWithAddress } from "../utils/utils";
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
  const rootBundleId = process.env.TEST_ROOT_BUNDLE_ID ?? 0;
  const spokeAddress = process.env.TEST_SPOKE_POOL_ADDRESS;
  if (!spokeAddress) {
    throw new Error("No spoke pool address specified. Please set TEST_SPOKE_POOL_ADDRESS to the target L2 spoke pool");
  }
  const tokenAddress = process.env.TEST_TOKEN_ADDRESS;
  if (!tokenAddress) {
    throw new Error(
      "No token address specified. Please set TEST_TOKEN_ADDRESS to the l2 token address to send back to the hub pool"
    );
  }
  const amountToReturn = process.env.AMOUNT_TO_RETURN;
  if (!amountToReturn) {
    throw new Error(
      "No AMOUNT_TO_RETURN in env. Please set AMOUNT_TO_RETURN to the amount of the l2 token to send back to the hub pool"
    );
  }

  const l2ChainId = parseInt(await hre.getChainId());
  const providerUrl =
    process.env[`NODE_URL_${l2ChainId}`] ?? `https://base-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`;
  const l2Provider = new ethers.providers.JsonRpcProvider(providerUrl);
  const l2Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l2Provider);
  const spokePool = new Contract(spokeAddress, ABI, l2Signer);

  const rootBundleType = "tuple(uint256,uint256,uint256[],uint32,address,address[])";
  // Construct the root bundle
  const encodedRootBundle = ethers.utils.defaultAbiCoder.encode(
    [rootBundleType],
    [[amountToReturn, l2ChainId, [], 0, tokenAddress, []]]
  );
  const rootBundleHash = ethers.utils.keccak256(encodedRootBundle);
  // Submit the root bundle to chain.
  const relayRootBundle = await spokePool.relayRootBundle(rootBundleHash, EMPTY_MERKLE_ROOT);
  console.log(`Sent relayer root ${rootBundleHash} to spoke pool with transaction hash ${relayRootBundle}`);
  // Execute the refund leaf.
  const executeRelayerRefundLeaf = await spokePool.executeRelayerRefundLeaf(
    rootBundleId,
    [amountToReturn, l2ChainId, [], 0, tokenAddress, []],
    []
  );
  console.log(`Executed root bundle with transaction hash ${executeRelayerRefundLeaf}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

// We only need to call two functions in this script: one to set a root bundle, and one to execute that set root bundle.
// This ABI should be consistent for all spoke pool implementations.
const ABI = `[
    {
        "inputs": [
            {
                "internalType": "uint32",
                "name": "rootBundleId",
                "type": "uint32"
            },
            {
                "components": [
                    {
                        "internalType": "uint256",
                        "name": "amountToReturn",
                        "type": "uint256"
                    },
                    {
                        "internalType": "uint256",
                        "name": "chainId",
                        "type": "uint256"
                    },
                    {
                        "internalType": "uint256[]",
                        "name": "refundAmounts",
                        "type": "uint256[]"
                    },
                    {
                        "internalType": "uint32",
                        "name": "leafId",
                        "type": "uint32"
                    },
                    {
                        "internalType": "address",
                        "name": "l2TokenAddress",
                        "type": "address"
                    },
                    {
                        "internalType": "address[]",
                        "name": "refundAddresses",
                        "type": "address[]"
                    }
                ],
                "internalType": "struct SpokePoolInterface.RelayerRefundLeaf",
                "name": "relayerRefundLeaf",
                "type": "tuple"
            },
            {
                "internalType": "bytes32[]",
                "name": "proof",
                "type": "bytes32[]"
            }
        ],
        "name": "executeRelayerRefundLeaf",
        "outputs": [],
        "stateMutability": "payable",
        "type": "function"
    },
    {
        "inputs": [
            {
                "internalType": "bytes32",
                "name": "relayerRefundRoot",
                "type": "bytes32"
            },
            {
                "internalType": "bytes32",
                "name": "slowRelayRoot",
                "type": "bytes32"
            }
        ],
        "name": "relayRootBundle",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "renounceOwnership",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [
            {
                "internalType": "uint256",
                "name": "",
                "type": "uint256"
            }
        ],
        "name": "rootBundles",
        "outputs": [
            {
                "internalType": "bytes32",
                "name": "slowRelayRoot",
                "type": "bytes32"
            },
            {
                "internalType": "bytes32",
                "name": "relayerRefundRoot",
                "type": "bytes32"
            }
        ],
        "stateMutability": "view",
        "type": "function"
    }
]`;
