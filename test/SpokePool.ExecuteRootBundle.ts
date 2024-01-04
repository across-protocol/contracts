import { MerkleTree } from "../utils/MerkleTree";
import {
  SignerWithAddress,
  seedContract,
  toBN,
  expect,
  Contract,
  ethers,
  BigNumber,
  createRandomBytes32,
} from "../utils/utils";
import * as consts from "./constants";
import { deployMockSpokePoolCaller, spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import {
  buildRelayerRefundTree,
  buildRelayerRefundLeaves,
  USSRelayerRefundLeaf,
  buildUSSRelayerRefundLeaves,
  buildUSSRelayerRefundTree,
} from "./MerkleLib.utils";

let spokePool: Contract, destErc20: Contract, weth: Contract;
let dataWorker: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let destinationChainId: number;

async function constructSimpleTree(l2Token: Contract, destinationChainId: number) {
  const leaves = buildRelayerRefundLeaves(
    [destinationChainId, destinationChainId], // Destination chain ID.
    [consts.amountToReturn, toBN(0)], // amountToReturn.
    [l2Token.address, l2Token.address], // l2Token.
    [[relayer.address, rando.address], []], // refundAddresses.
    [[consts.amountToRelay, consts.amountToRelay], []] // refundAmounts.
  );
  const leavesRefundAmount = leaves
    .map((leaf) => leaf.refundAmounts.reduce((bn1, bn2) => bn1.add(bn2), toBN(0)))
    .reduce((bn1, bn2) => bn1.add(bn2), toBN(0));
  const tree = await buildRelayerRefundTree(leaves);

  return { leaves, leavesRefundAmount, tree };
}
describe("SpokePool Root Bundle Execution", function () {
  beforeEach(async function () {
    [dataWorker, relayer, rando] = await ethers.getSigners();
    ({ destErc20, spokePool, weth } = await spokePoolFixture());
    destinationChainId = Number(await spokePool.chainId());

    // Send funds to SpokePool.
    await seedContract(spokePool, dataWorker, [destErc20], weth, consts.amountHeldByPool);
  });

  it("Execute relayer root correctly sends tokens to recipients", async function () {
    const { leaves, leavesRefundAmount, tree } = await constructSimpleTree(destErc20, destinationChainId);

    // Store new tree.
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // relayer refund root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Distribute the first leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // Relayers should be refunded
    expect(await destErc20.balanceOf(spokePool.address)).to.equal(consts.amountHeldByPool.sub(leavesRefundAmount));
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToRelay);
    expect(await destErc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);

    // Check events.
    let relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    expect(relayTokensEvents[0].args?.l2TokenAddress).to.equal(destErc20.address);
    expect(relayTokensEvents[0].args?.leafId).to.equal(0);
    expect(relayTokensEvents[0].args?.chainId).to.equal(destinationChainId);
    expect(relayTokensEvents[0].args?.amountToReturn).to.equal(consts.amountToReturn);
    expect((relayTokensEvents[0].args?.refundAmounts as BigNumber[]).map((v) => v.toString())).to.deep.equal(
      [consts.amountToRelay, consts.amountToRelay].map((v) => v.toString())
    );
    expect(relayTokensEvents[0].args?.refundAddresses).to.deep.equal([relayer.address, rando.address]);

    // Should emit TokensBridged event if amountToReturn is positive.
    let tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    expect(tokensBridgedEvents.length).to.equal(1);

    // Does not attempt to bridge tokens if amountToReturn is 0. Execute a leaf where amountToReturn is 0.
    await spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[1], tree.getHexProof(leaves[1]));

    // Show that a second DistributedRelayRefund event was emitted but not a second TokensBridged event.
    relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    expect(relayTokensEvents.length).to.equal(2);
    tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    expect(tokensBridgedEvents.length).to.equal(1);
  });

  it("Execution rejects invalid leaf, tree, proof combinations", async function () {
    const { leaves, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Take the valid root but change some element within it. This will change the hash of the leaf
    // and as such the contract should reject it for not being included within the merkle tree for the valid proof.
    const badLeaf = { ...leaves[0], chainId: 13371 };
    await expect(spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, badLeaf, tree.getHexProof(leaves[0]))).to.be
      .reverted;

    // Reverts if the distribution root index is incorrect.
    await expect(spokePool.connect(dataWorker).executeRelayerRefundLeaf(1, leaves[0], tree.getHexProof(leaves[0]))).to
      .be.reverted;
  });
  it("Cannot refund leaf with chain ID for another network", async function () {
    // Create tree for another chain ID
    const { leaves, tree } = await constructSimpleTree(destErc20, 13371);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Root is valid and leaf is contained in tree, but chain ID doesn't match pool's chain ID.
    await expect(spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))).to
      .be.reverted;
  });
  it("Execution rejects double claimed leaves", async function () {
    const { leaves, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // First claim should be fine. Second claim should be reverted as you cant double claim a leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));
    await expect(spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))).to
      .be.reverted;
  });

  describe("USS relayer refund leaves", function () {
    let leaves: USSRelayerRefundLeaf[], tree: MerkleTree<USSRelayerRefundLeaf>;
    beforeEach(async function () {
      leaves = buildUSSRelayerRefundLeaves(
        [destinationChainId, destinationChainId], // Destination chain ID.
        [consts.amountToReturn, toBN(0)], // amountToReturn.
        [destErc20.address, destErc20.address], // l2Token.
        [[relayer.address, rando.address], []], // refundAddresses.
        [[consts.amountToRelay, consts.amountToRelay], []], // refundAmounts.
        [createRandomBytes32(), consts.mockTreeRoot], // fillsRefundedRoot.
        [createRandomBytes32(), consts.mockTreeRoot] // fillsRefundedHash.
      );
      tree = await buildUSSRelayerRefundTree(leaves);
    });
    it("Happy case: relayer can execute leaf to payout ERC20 tokens from spoke pool", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(() =>
        spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.changeTokenBalances(
        destErc20,
        [relayer, rando, spokePool],
        [consts.amountToRelay, consts.amountToRelay, consts.amountToRelay.mul(-2)]
      );
    });
    it("calls _preExecuteLeafHook", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0])))
        .to.emit(spokePool, "PreLeafExecuteHook")
        .withArgs(leaves[0].l2TokenAddress);
    });
    it("cannot re-enter", async function () {
      const functionCalldata = spokePool.interface.encodeFunctionData("executeUSSRelayerRefundLeaf", [
        0,
        leaves[0],
        tree.getHexProof(leaves[0]),
      ]);
      await expect(spokePool.connect(dataWorker).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
    it("can execute even if fills are paused", async function () {
      await spokePool.pauseFills(true);
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(relayer).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))).to
        .not.be.reverted;
    });
    it("cannot execute leaves with chain IDs not matching spoke pool's chain ID", async function () {
      // In this test, the merkle proof is valid for the tree relayed to the spoke pool, but the merkle leaf
      // destination chain ID does not match the spoke pool's chainId() and therefore cannot be executed.
      const leafWithWrongDestinationChain: USSRelayerRefundLeaf = {
        ...leaves[0],
        chainId: leaves[0].chainId.add(1),
      };
      const treeWithWrongDestinationChain = await buildUSSRelayerRefundTree([leafWithWrongDestinationChain]);
      await spokePool
        .connect(dataWorker)
        .relayRootBundle(treeWithWrongDestinationChain.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(
        spokePool
          .connect(dataWorker)
          .executeUSSRelayerRefundLeaf(
            0,
            leafWithWrongDestinationChain,
            treeWithWrongDestinationChain.getHexProof(leafWithWrongDestinationChain)
          )
      ).to.be.revertedWith("InvalidChainId");
    });
    it("invalid merkle proof", async function () {
      // Relay two root bundles:
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockSlowRelayRoot, consts.mockSlowRelayRoot);

      // Incorrect root bundle ID
      await expect(
        spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(
          1, // rootBundleId should be 0
          leaves[0],
          tree.getHexProof(leaves[0])
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect relayer refund leaf for proof
      await expect(
        spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(
          0,
          leaves[1], // Should be leaves[0]
          tree.getHexProof(leaves[0])
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect proof
      await expect(
        spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(
          0,
          leaves[0],
          tree.getHexProof(leaves[1]) // Should be leaves[0]
        )
      ).to.revertedWith("InvalidMerkleProof");
    });
    it("cannot double claim", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));
      await expect(
        spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.be.revertedWith("ClaimedMerkleLeaf");
    });
    it("emits expected events", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(dataWorker).executeUSSRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0])))
        .to.emit(spokePool, "ExecutedUSSRelayerRefundRoot")
        .withArgs(
          leaves[0].amountToReturn,
          leaves[0].chainId,
          leaves[0].refundAmounts,
          0, // rootBundleId
          leaves[0].leafId,
          leaves[0].l2TokenAddress,
          leaves[0].refundAddresses,
          leaves[0].fillsRefundedRoot,
          leaves[0].fillsRefundedHash
        );
    });
  });

  describe("Gas test", function () {
    // Run following tests with REPORT_GAS=true to print out isolated gas costs for internal functions
    // that are called directly by the MockSpokePool.
    it("_distributeRelayerRefunds: amountToReturn > 0", async function () {
      const { leaves, tree } = await constructSimpleTree(destErc20, destinationChainId);
      await spokePool.connect(dataWorker).relayRootBundle(
        tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
        consts.mockSlowRelayRoot
      );

      const leaf = leaves[0];
      expect(leaf.amountToReturn).to.be.gt(0);
      await spokePool
        .connect(dataWorker)
        .distributeRelayerRefunds(
          leaf.chainId,
          leaf.amountToReturn,
          leaf.refundAmounts,
          leaf.leafId,
          leaf.l2TokenAddress,
          leaf.refundAddresses
        );
    });
  });
});
