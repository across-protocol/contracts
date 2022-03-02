import { toBNWei, SignerWithAddress, Contract, ethers, toBN, expect, seedContract } from "../utils";
import { deployErc20 } from "./utils";
import * as consts from "../constants";
import { spokePoolFixture, RelayData } from "../fixtures/SpokePool.Fixture";
import { buildSlowRelayTree } from "../MerkleLib.utils";
import { MerkleTree } from "../../utils/MerkleTree";

require("dotenv").config();

let spokePool: Contract, weth: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, recipient: SignerWithAddress;

// Associates an array of L2 tokens to fill relays with.
let l2Tokens: Contract[];
let leaves: RelayData[];
let tree: MerkleTree<RelayData>;

// Relay params that do not affect tests and we can conveniently hardcode:
const ORIGIN_CHAIN_ID = "0";
const FEE_PCT = "0";

// Constants caller can tune to modify gas tests.
const LEAF_COUNT = 10;
const RELAY_AMOUNT = toBNWei("1");

// Construct tree with LEAF_COUNT leaves. Each relay will have a deposit ID equal to its index in the array of relays.
async function constructSimpleTree(
  depositor: string,
  recipient: string,
  destinationTokens: string[],
  universalRelayAmount: string
) {
  // Each refund amount mapped to one refund address.
  expect(destinationTokens.length).to.equal(LEAF_COUNT);

  const relays: RelayData[] = [];
  for (let i = 0; i < LEAF_COUNT; i++) {
    relays.push({
      depositor,
      recipient,
      destinationToken: destinationTokens[i],
      amount: universalRelayAmount,
      originChainId: ORIGIN_CHAIN_ID,
      realizedLpFeePct: FEE_PCT,
      relayerFeePct: FEE_PCT,
      depositId: i.toString(),
    });
  }
  const tree = await buildSlowRelayTree(relays);

  return { leaves: relays, tree };
}

describe("Gas Analytics: SpokePool Slow Relay Root Execution", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [owner, dataWorker, recipient] = await ethers.getSigners();
    ({ spokePool, weth } = await spokePoolFixture());

    // Deploy test tokens for each chain ID
    l2Tokens = [];
    for (let i = 0; i < LEAF_COUNT; i++) {
      const token = await deployErc20(owner, `Test Token #${i}`, `T-${i}`);
      l2Tokens.push(token);

      // Seed spoke pool with amount needed to cover all relay fills for L2 token.
      await token.connect(owner).mint(spokePool.address, RELAY_AMOUNT.mul(toBN(2)));
    }

    // Seed pool with WETH for WETH tests
    await seedContract(spokePool, owner, [], weth, RELAY_AMOUNT.mul(LEAF_COUNT).mul(toBN(2)));
  });

  describe(`(ERC20) Tree with ${LEAF_COUNT} leaves`, function () {
    beforeEach(async function () {
      // Change relay amount so we don't send tokens from the pool and the root is different.
      const initTree = await constructSimpleTree(
        owner.address,
        recipient.address,
        l2Tokens.map((token) => token.address),
        "1"
      );

      // Store new tree.
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, initTree.tree.getHexRoot());

      // Execute 1 leaf from initial tree to warm state storage.
      await spokePool
        .connect(dataWorker)
        .executeSlowRelayRoot(
          owner.address,
          recipient.address,
          l2Tokens[0].address,
          "1",
          ORIGIN_CHAIN_ID,
          FEE_PCT,
          FEE_PCT,
          "0",
          "0",
          initTree.tree.getHexProof(initTree.leaves[0])
        );

      const simpleTree = await constructSimpleTree(
        owner.address,
        recipient.address,
        l2Tokens.map((token) => token.address),
        RELAY_AMOUNT.toString()
      );
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
    });

    it("Relay proposal", async function () {
      const txn = await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, tree.getHexRoot());
      console.log(`relayRootBundle-gasUsed: ${(await txn.wait()).gasUsed}`);
    });

    it("Executing 1 leaf", async function () {
      const leafIndexToExecute = 0;

      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, tree.getHexRoot());

      // Execute second root bundle with index 1:
      const txn = await spokePool
        .connect(dataWorker)
        .executeSlowRelayRoot(
          owner.address,
          recipient.address,
          l2Tokens[0].address,
          RELAY_AMOUNT,
          ORIGIN_CHAIN_ID,
          FEE_PCT,
          FEE_PCT,
          "0",
          "1",
          tree.getHexProof(leaves[leafIndexToExecute])
        );
      const receipt = await txn.wait();
      console.log(`executeSlowRelayRoot-gasUsed: ${receipt.gasUsed}`);
    });
    it("Executing all leaves", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, tree.getHexRoot());

      const txns = [];
      for (let i = 0; i < LEAF_COUNT; i++) {
        txns.push(
          await spokePool
            .connect(dataWorker)
            .executeSlowRelayRoot(
              owner.address,
              recipient.address,
              l2Tokens[i].address,
              RELAY_AMOUNT,
              ORIGIN_CHAIN_ID,
              FEE_PCT,
              FEE_PCT,
              i,
              "1",
              tree.getHexProof(leaves[i])
            )
        );
      }

      // Compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) executeSlowRelayRoot-gasUsed: ${gasUsed.div(LEAF_COUNT)}`);
    });

    it("Executing all leaves using multicall", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, tree.getHexRoot());

      const multicallData = leaves.map((leaf, i) => {
        return spokePool.interface.encodeFunctionData("executeSlowRelayRoot", [
          owner.address,
          recipient.address,
          l2Tokens[i].address,
          RELAY_AMOUNT,
          ORIGIN_CHAIN_ID,
          FEE_PCT,
          FEE_PCT,
          i,
          "1",
          tree.getHexProof(leaf),
        ]);
      });

      const receipt = await (await spokePool.connect(dataWorker).multicall(multicallData)).wait();
      console.log(`(average) executeSlowRelayRoot-gasUsed: ${receipt.gasUsed.div(LEAF_COUNT)}`);
    });
  });
  describe(`(WETH) Tree with ${LEAF_COUNT} leaves`, function () {
    beforeEach(async function () {
      // Change relay amount so we don't send tokens from the pool and the root is different.
      const initTree = await constructSimpleTree(
        owner.address,
        recipient.address,
        Array(LEAF_COUNT).fill(weth.address),
        "1"
      );

      // Store new tree.
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, initTree.tree.getHexRoot());

      // Execute 1 leaf from initial tree to warm state storage.
      await spokePool
        .connect(dataWorker)
        .executeSlowRelayRoot(
          owner.address,
          recipient.address,
          weth.address,
          "1",
          ORIGIN_CHAIN_ID,
          FEE_PCT,
          FEE_PCT,
          "0",
          "0",
          initTree.tree.getHexProof(initTree.leaves[0])
        );

      const simpleTree = await constructSimpleTree(
        owner.address,
        recipient.address,
        Array(LEAF_COUNT).fill(weth.address),
        RELAY_AMOUNT.toString()
      );
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
    });

    it("Executing 1 leaf", async function () {
      const leafIndexToExecute = 0;

      await spokePool.connect(dataWorker).relayRootBundle(consts.mockRelayerRefundRoot, tree.getHexRoot());

      // Execute second root bundle with index 1:
      const txn = await spokePool
        .connect(dataWorker)
        .executeSlowRelayRoot(
          owner.address,
          recipient.address,
          weth.address,
          RELAY_AMOUNT,
          ORIGIN_CHAIN_ID,
          FEE_PCT,
          FEE_PCT,
          "0",
          "1",
          tree.getHexProof(leaves[leafIndexToExecute])
        );
      const receipt = await txn.wait();
      console.log(`executeSlowRelayRoot-gasUsed: ${receipt.gasUsed}`);
    });
  });
});
