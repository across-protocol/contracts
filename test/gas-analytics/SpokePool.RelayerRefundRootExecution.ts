import {
  toBNWei,
  SignerWithAddress,
  Contract,
  ethers,
  BigNumber,
  expect,
  seedContract,
  toBN,
  seedWallet,
} from "../utils";
import { deployErc20, warmSpokePool } from "./utils";
import * as consts from "../constants";
import { spokePoolFixture } from "../fixtures/SpokePool.Fixture";
import { RelayerRefundLeaf, buildRelayerRefundLeafs, buildRelayerRefundTree } from "../MerkleLib.utils";
import { MerkleTree } from "../../utils/MerkleTree";

require("dotenv").config();

let spokePool: Contract, weth: Contract;
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
// Regarding the block limit, the max limit is 30 million gas, the expected block gas limit is 15 million, so
// we'll target 12 million gas as a conservative upper-bound. This test script will fail if executing a leaf with
// `STRESS_TEST_REFUND_COUNT` number of refunds is not within the [TARGET_GAS_LOWER_BOUND, TARGET_GAS_UPPER_BOUND]
// gas usage range.
const TARGET_GAS_UPPER_BOUND = 12_000_000;
const TARGET_GAS_LOWER_BOUND = 6_000_000;
// Note: I can't get this to work with a gas > 8mil without the transaction timing out. This is why I've set
// the lower bound to 6mil instead of a tighter 10mil.
const STRESS_TEST_REFUND_COUNT = 1000;

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
    ({ spokePool, weth } = await spokePoolFixture());

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
      // Note: Mint more than needed for this test to simulate production, otherwise reported gas costs
      // will be better because a storage slot is deleted.
      const totalRefundAmount = REFUND_AMOUNT.mul(REFUNDS_PER_LEAF);
      await token.connect(owner).mint(spokePool.address, totalRefundAmount.mul(toBN(5)));

      await seedWallet(owner, [token], weth, totalRefundAmount.mul(toBN(5)));
      await token.connect(owner).approve(spokePool.address, consts.maxUint256);
      await warmSpokePool(spokePool, owner, recipient, token.address, totalRefundAmount, totalRefundAmount, 0);
    }

    // Seed pool with WETH for WETH tests
    await seedContract(
      spokePool,
      owner,
      [],
      weth,
      REFUND_AMOUNT.mul(REFUNDS_PER_LEAF).mul(REFUND_LEAF_COUNT).mul(toBN(5))
    );
    await weth.connect(owner).approve(spokePool.address, consts.maxUint256);
    await warmSpokePool(
      spokePool,
      owner,
      dataWorker,
      weth.address,
      REFUND_AMOUNT.mul(REFUNDS_PER_LEAF),
      REFUND_AMOUNT.mul(REFUNDS_PER_LEAF),
      0
    );
  });

  describe(`(ERC20) Tree with ${REFUND_LEAF_COUNT} leaves, each containing ${REFUNDS_PER_LEAF} refunds`, function () {
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
  describe(`(WETH): Relayer Refund tree with ${REFUND_LEAF_COUNT} leaves, each containing ${REFUNDS_PER_LEAF} refunds`, function () {
    beforeEach(async function () {
      // Change refund amount to 0 so we don't send tokens from the pool and the root is different.
      const initTree = await constructSimpleTree(
        destinationChainIds,
        Array(REFUND_LEAF_COUNT).fill(weth.address),
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
        Array(REFUND_LEAF_COUNT).fill(weth.address),
        amountsToReturn,
        REFUND_AMOUNT,
        refundAddresses
      );
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
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
    it(`Stress Test: 1 leaf contains ${STRESS_TEST_REFUND_COUNT} refunds with amount > 0`, async function () {
      // This test should inform the limit # refunds that we would allow a RelayerRefundLeaf to contain to avoid
      // publishing a leaf that is unexecutable due to the block gas limit.

      // Note: Since the SpokePool is deployed on L2s we care specifically about L2 block gas limits.
      // - Optimism: same as L1
      // - Arbitrum: TODO
      // - Polygon: same as L1

      // Regarding the block limit, the max limit is 30 million gas, the expected block gas limit is 15 million, so
      // we'll target 12 million gas as a conservative upper-bound.
      await seedContract(spokePool, owner, [], weth, toBN(STRESS_TEST_REFUND_COUNT).mul(REFUND_AMOUNT).mul(toBN(10)));

      // Create tree with 1 large leaf.
      const bigLeaves = buildRelayerRefundLeafs(
        [destinationChainIds[0]],
        [toBNWei("1")], // Set amount to return > 0 to better simulate long execution path of _executeRelayerRefundLeaf
        [weth.address],
        [Array(STRESS_TEST_REFUND_COUNT).fill(recipient.address)],
        [Array(STRESS_TEST_REFUND_COUNT).fill(REFUND_AMOUNT)]
      );
      const bigLeafTree = await buildRelayerRefundTree(bigLeaves);

      await spokePool.connect(dataWorker).relayRootBundle(bigLeafTree.getHexRoot(), consts.mockSlowRelayRoot);

      // Estimate the transaction gas and set it (plus some buffer) explicitly as the transaction's gas limit. This is
      // done because ethers.js' default gas limit setting doesn't seem to always work and sometimes overestimates
      // it and throws something like:
      // "InvalidInputError: Transaction gas limit is X and exceeds block gas limit of 30000000"
      const gasEstimate = await spokePool
        .connect(dataWorker)
        .estimateGas.executeRelayerRefundRoot(1, bigLeaves[0], bigLeafTree.getHexProof(bigLeaves[0]));
      const txn = await spokePool
        .connect(dataWorker)
        .executeRelayerRefundRoot(1, bigLeaves[0], bigLeafTree.getHexProof(bigLeaves[0]), {
          gasLimit: gasEstimate.mul(toBN("1.2")),
        });

      const receipt = await txn.wait();
      console.log(`executeRelayerRefundRoot-gasUsed: ${receipt.gasUsed}`);
      expect(Number(receipt.gasUsed)).to.be.lessThanOrEqual(TARGET_GAS_UPPER_BOUND);
      expect(Number(receipt.gasUsed)).to.be.greaterThanOrEqual(TARGET_GAS_LOWER_BOUND);
    });
  });
});
