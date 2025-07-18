// @notice Run script to produce simple merkle roots required to test the HubPool/SpokePool interaction on a public
//         test net.
// @dev    Modify constants to modify merkle leaves. Command: `yarn hardhat run ./scripts/buildSampleTree.ts`

import {
  toBN,
  getParamType,
  defaultAbiCoder,
  keccak256,
  toBNWeiWithDecimals,
  createRandomBytes32,
} from "../utils/utils";
import { MerkleTree } from "../utils/MerkleTree";
import { V3SlowFill } from "../test/evm/hardhat/fixtures/SpokePool.Fixture";

import { PoolRebalanceLeaf, RelayerRefundLeaf } from "../test/evm/hardhat/MerkleLib.utils";
import { zeroAddress } from "../test-utils";

// Any variables not configurable in this set of constants is not used in this script and not important for testing in
// production.
const POOL_REBALANCE_LEAF_COUNT = 1;
const RELAYER_REFUND_LEAF_COUNT = 1;
const SLOW_RELAY_LEAF_COUNT = 1;
const POOL_REBALANCE_NET_SEND_AMOUNT = 0.1; // Amount of tokens to send from HubPool to SpokePool
const RELAYER_REFUND_AMOUNT_TO_RETURN = 0.1; // Amount of tokens to send from SpokePool to HubPool
const L1_TOKEN = "0x40153ddfad90c49dbe3f5c9f96f2a5b25ec67461";
const L2_TOKEN = "0x40153ddfad90c49dbe3f5c9f96f2a5b25ec67461";
const DECIMALS = 18;
const RELAYER_REFUND_ADDRESS_TO_REFUND = "0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d";
const RELAYER_REFUND_AMOUNT_TO_REFUND = 0.1; // Amount of tokens to send out of SpokePool to relayer refund recipient
const SLOW_RELAY_RECIPIENT_ADDRESS = "0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d";
const SLOW_RELAY_AMOUNT = 0.1; // Amount of tokens to send out of SpokePool to slow relay recipient address
const SPOKE_POOL_CHAIN_ID = 5;

function tuplelifyLeaf(leaf: Object) {
  return JSON.stringify(
    Object.values(leaf).map((x: any) => (Array.isArray(x) ? x.map((y: any) => y.toString()) : x.toString()))
  );
}

async function main() {
  if (POOL_REBALANCE_LEAF_COUNT > 0) {
    console.group(
      `\nGenerating pool rebalance merkle tree with ${POOL_REBALANCE_LEAF_COUNT} identical lea${
        POOL_REBALANCE_LEAF_COUNT > 1 ? "ves" : "f"
      }`
    );
    const leaves: PoolRebalanceLeaf[] = [];
    for (let i = 0; i < POOL_REBALANCE_LEAF_COUNT; i++) {
      leaves.push({
        chainId: toBN(SPOKE_POOL_CHAIN_ID),
        bundleLpFees: [toBN(0)],
        netSendAmounts: [toBNWeiWithDecimals(POOL_REBALANCE_NET_SEND_AMOUNT, DECIMALS)],
        runningBalances: [toBN(0)],
        groupIndex: toBN(0),
        leafId: toBN(i),
        l1Tokens: [L1_TOKEN],
      });
      console.group();
      console.log(`- poolRebalanceLeaf ID#${i}: `, leaves[i]);
      console.log("- Tuple representation of leaf that you can input into etherscan.io: \n", tuplelifyLeaf(leaves[i]));
      console.groupEnd();
    }

    console.log(
      `- To execute this root, the HubPool needs to have at least ${
        POOL_REBALANCE_NET_SEND_AMOUNT * POOL_REBALANCE_LEAF_COUNT
      } amount of ${L1_TOKEN} to bridge to the SpokePool`
    );

    const paramType = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
    const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const tree = new MerkleTree<PoolRebalanceLeaf>(leaves, hashFn);
    console.log("- Pool rebalance root: ", tree.getHexRoot());
    console.group();
    for (let i = 0; i < POOL_REBALANCE_LEAF_COUNT; i++) {
      console.log(`- Proof for leaf ID#${i}: `, tree.getHexProof(leaves[i]));
    }
    console.groupEnd();

    console.groupEnd();
  }

  if (RELAYER_REFUND_LEAF_COUNT > 0) {
    console.group(
      `\nGenerating relayer refund merkle tree with ${RELAYER_REFUND_LEAF_COUNT} identical lea${
        RELAYER_REFUND_LEAF_COUNT > 1 ? "ves" : "f"
      }`
    );
    const leaves: RelayerRefundLeaf[] = [];
    for (let i = 0; i < RELAYER_REFUND_LEAF_COUNT; i++) {
      leaves.push({
        amountToReturn: toBNWeiWithDecimals(RELAYER_REFUND_AMOUNT_TO_RETURN, DECIMALS),
        chainId: toBN(SPOKE_POOL_CHAIN_ID),
        refundAmounts: [toBNWeiWithDecimals(RELAYER_REFUND_AMOUNT_TO_REFUND, DECIMALS)],
        leafId: toBN(i),
        l2TokenAddress: L2_TOKEN,
        refundAddresses: [RELAYER_REFUND_ADDRESS_TO_REFUND],
      });
      console.group();
      console.log(`- relayerRefundLeaf ID#${i}: `, leaves[i]);
      console.log("- Tuple representation of leaf that you can input into etherscan.io: \n", tuplelifyLeaf(leaves[i]));
      console.groupEnd();
    }

    console.log(
      `- To execute this root, the SpokePool needs to have at least ${
        (RELAYER_REFUND_AMOUNT_TO_RETURN + RELAYER_REFUND_AMOUNT_TO_REFUND) * RELAYER_REFUND_LEAF_COUNT
      } amount of ${L2_TOKEN} to bridge to the HubPool and send ${RELAYER_REFUND_LEAF_COUNT} refunds`
    );

    const paramType = await getParamType("MerkleLibTest", "verifyRelayerRefund", "refund");
    const hashFn = (input: RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const tree = new MerkleTree<RelayerRefundLeaf>(leaves, hashFn);
    console.log("- Relayer refund root: ", tree.getHexRoot());
    console.group();
    for (let i = 0; i < RELAYER_REFUND_LEAF_COUNT; i++) {
      console.log(`- Proof for leaf ID#${i}: `, tree.getHexProof(leaves[i]));
    }
    console.groupEnd();

    console.groupEnd();
  }

  if (SLOW_RELAY_LEAF_COUNT > 0) {
    console.group(
      `\nGenerating slow relay fulfillment merkle tree with ${SLOW_RELAY_LEAF_COUNT} identical lea${
        SLOW_RELAY_LEAF_COUNT > 1 ? "ves" : "f"
      }`
    );
    const leaves: V3SlowFill[] = [];
    for (let i = 0; i < SLOW_RELAY_LEAF_COUNT; i++) {
      leaves.push({
        relayData: {
          depositor: SLOW_RELAY_RECIPIENT_ADDRESS,
          recipient: SLOW_RELAY_RECIPIENT_ADDRESS,
          exclusiveRelayer: zeroAddress,
          inputToken: L1_TOKEN,
          outputToken: L2_TOKEN,
          inputAmount: toBNWeiWithDecimals(SLOW_RELAY_AMOUNT, DECIMALS),
          outputAmount: toBNWeiWithDecimals(SLOW_RELAY_AMOUNT, DECIMALS),
          originChainId: SPOKE_POOL_CHAIN_ID,
          fillDeadline: Math.floor(Date.now() / 1000) + 14400, // 4 hours from now
          exclusivityDeadline: 0,
          depositId: toBN(i),
          message: "0x",
        },
        updatedOutputAmount: toBNWeiWithDecimals(SLOW_RELAY_AMOUNT, DECIMALS),
        chainId: SPOKE_POOL_CHAIN_ID,
      });
      console.group();
      console.log(`- slowRelayLeaf ID#${i}: `, leaves[i]);
      console.log(
        "- Tuple representation of leaf that you can input into etherscan.io: \n",
        tuplelifyLeaf(leaves[i].relayData)
      );
      console.groupEnd();
    }

    console.log(
      `- To execute this root, the SpokePool needs to have at least ${
        SLOW_RELAY_AMOUNT * SLOW_RELAY_LEAF_COUNT
      } amount of ${L2_TOKEN} to fulfill ${SLOW_RELAY_LEAF_COUNT} relays`
    );

    const paramType = await getParamType("MerkleLibTest", "verifyV3SlowRelayFulfillment", "slowFill");
    const hashFn = (input: V3SlowFill) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const tree = new MerkleTree<V3SlowFill>(leaves, hashFn);
    console.log("- Slow relay root: ", tree.getHexRoot());
    console.group();
    for (let i = 0; i < SLOW_RELAY_LEAF_COUNT; i++) {
      console.log(`- Proof for leaf ID#${i}: `, tree.getHexProof(leaves[i]));
    }
    console.groupEnd();

    console.groupEnd();
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
