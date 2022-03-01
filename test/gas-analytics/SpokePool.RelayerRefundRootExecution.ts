import { toBNWei, SignerWithAddress, Contract, ethers, BigNumber, expect } from "../utils";
import { deployErc20 } from "./utils";
import * as consts from "../constants";
import { spokePoolFixture } from "../SpokePool.Fixture";
import { RelayerRefundLeaf, buildRelayerRefundLeafs, buildRelayerRefundTree } from "../MerkleLib.utils";
import { MerkleTree } from "../../utils/MerkleTree";

require("dotenv").config();

let spokePool: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, recipient: SignerWithAddress;

// Associates an array of L2 tokens to sends refunds.
let destinationChainIds: number[];
let l2Tokens: Contract[];
let refundAddresses: string[];
let amountsToReturn: BigNumber[];
let leaves: RelayerRefundLeaf[];
let tree: MerkleTree<RelayerRefundLeaf>;

// Constants caller can tune to modify gas tests.
const REFUND_LEAF_COUNT = 10;
const REFUNDS_PER_LEAF = 10;
const REFUND_AMOUNT = toBNWei("10");

// Construct tree with REFUND_LEAF_COUNT leaves, each containing REFUNDS_PER_LEAF refunds.
async function constructSimpleTree(
  _destinationChainIds: number[],
  _l2Tokens: string[],
  _amountsToReturn: BigNumber[],
  _universalRefundAmount: BigNumber,
  refundAddresses: string[] // Should be same length as REFUNDS_PER_LEAF
) {
  // Each refund amount mapped to one refund address.
  expect(refundAddresses.length).to.equal(REFUNDS_PER_LEAF);
  // Each refund has 1 dest. chain ID, 1 amount to return, and 1 L2 token.
  expect(_destinationChainIds.length).to.equal(REFUND_LEAF_COUNT);
  expect(_amountsToReturn.length).to.equal(REFUND_LEAF_COUNT);
  expect(_l2Tokens.length).to.equal(REFUND_LEAF_COUNT);

  const _refundAmounts: BigNumber[][] = [];
  const _refundAddresses: string[][] = [];
  for (let i = 0; i < REFUND_LEAF_COUNT; i++) {
    _refundAmounts[i] = [];
    _refundAddresses[i] = [];
    for (let j = 0; j < REFUNDS_PER_LEAF; j++) {
      _refundAmounts[i].push(_universalRefundAmount);
      _refundAddresses[i].push(refundAddresses[j]);
    }
  }
  const leaves = buildRelayerRefundLeafs(
    _destinationChainIds,
    _amountsToReturn,
    _l2Tokens,
    _refundAddresses,
    _refundAmounts
  );
  const tree = await buildRelayerRefundTree(leaves);

  return { leaves, tree };
}

describe("Gas Analytics: SpokePool Relayer Refund Root Execution", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [owner, dataWorker, recipient] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());

    const destinationChainId = Number(await spokePool.chainId());
    destinationChainIds = Array(REFUND_LEAF_COUNT).fill(destinationChainId);
    amountsToReturn = Array(REFUND_LEAF_COUNT).fill(toBNWei("1"));
    refundAddresses = Array(REFUNDS_PER_LEAF).fill(recipient.address);

    // Deploy test tokens for each chain ID
    l2Tokens = [];
    for (let i = 0; i < REFUND_LEAF_COUNT; i++) {
      const token = await deployErc20(owner, `Test Token #${i}`, `T-${i}`);
      l2Tokens.push(token);

      // Seed spoke pool with amount needed to cover all refunds for L2 token, which is used for 1 refund leaf.
      const totalRefundAmount = REFUND_AMOUNT.mul(REFUNDS_PER_LEAF);
      await token.connect(owner).mint(spokePool.address, totalRefundAmount);
    }
  });

  describe(`Tree with ${REFUND_LEAF_COUNT} leaves, each containing ${REFUNDS_PER_LEAF} refunds`, function () {
    beforeEach(async function () {
      // Change refund amount to 0 so we don't send tokens from the pool and the root is different.
      const initTree = await constructSimpleTree(
        destinationChainIds,
        l2Tokens.map((token) => token.address),
        amountsToReturn,
        toBNWei("0"),
        refundAddresses
      );

      // Store new tree.
      await spokePool.connect(dataWorker).relayRootBundle(
        initTree.tree.getHexRoot(), // relayer refund root. Generated from the merkle tree constructed before.
        consts.mockSlowRelayRoot
      );

      // Execute 1 leaf from initial tree to warm state storage.
      await spokePool
        .connect(dataWorker)
        .executeRelayerRefundRoot(0, initTree.leaves[0], initTree.tree.getHexProof(initTree.leaves[0]));

      const simpleTree = await constructSimpleTree(
        destinationChainIds,
        l2Tokens.map((token) => token.address),
        amountsToReturn,
        REFUND_AMOUNT,
        refundAddresses
      );
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
    });

    it("Relay proposal", async function () {
      const txn = await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      console.log(`relayRootBundle-gasUsed: ${(await txn.wait()).gasUsed}`);
    });

    it("Executing 1 leaf", async function () {
      const leafIndexToExecute = 0;

      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);

      // Execute second root bundle with index 1:
      const txn = await spokePool
        .connect(dataWorker)
        .executeRelayerRefundRoot(1, leaves[leafIndexToExecute], tree.getHexProof(leaves[leafIndexToExecute]));

      const receipt = await txn.wait();
      console.log(`executeRelayerRefundRoot-gasUsed: ${receipt.gasUsed}`);
    });
    it("Executing all leaves", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);

      const txns = [];
      for (let i = 0; i < REFUND_LEAF_COUNT; i++) {
        txns.push(
          await spokePool.connect(dataWorker).executeRelayerRefundRoot(1, leaves[i], tree.getHexProof(leaves[i]))
        );
      }

      // Compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) executeRelayerRefundRoot-gasUsed: ${gasUsed.div(REFUND_LEAF_COUNT)}`);
    });

    it("Executing all leaves using multicall", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);

      const multicallData = leaves.map((leaf) => {
        return spokePool.interface.encodeFunctionData("executeRelayerRefundRoot", [1, leaf, tree.getHexProof(leaf)]);
      });

      const receipt = await (await spokePool.connect(dataWorker).multicall(multicallData)).wait();
      console.log(`(average) executeRelayerRefundRoot-gasUsed: ${receipt.gasUsed.div(REFUND_LEAF_COUNT)}`);
    });
  });
  describe(`(WETH): Relayer Refund tree with ${REFUND_LEAF_COUNT} leaves, each containing ${REFUNDS_PER_LEAF} refunds`, function () {});
});
