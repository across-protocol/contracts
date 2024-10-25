import {
  SignerWithAddress,
  seedContract,
  toBN,
  expect,
  Contract,
  ethers,
  BigNumber,
  addressToBytes,
  bytes32ToAddress,
} from "../../../utils/utils";
import * as consts from "./constants";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { buildRelayerRefundTree, buildRelayerRefundLeaves } from "./MerkleLib.utils";

let spokePool: Contract, destErc20: Contract, weth: Contract;
let dataWorker: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let destinationChainId: number;

async function constructSimpleTree(l2Token: Contract, destinationChainId: number) {
  const leaves = buildRelayerRefundLeaves(
    [destinationChainId, destinationChainId], // Destination chain ID.
    [consts.amountToReturn, toBN(0)], // amountToReturn.
    [addressToBytes(l2Token.address), addressToBytes(l2Token.address)], // l2Token.
    [[addressToBytes(relayer.address), addressToBytes(rando.address)], []], // refundAddresses.
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
    expect(relayTokensEvents[0].args?.l2TokenAddress).to.equal(addressToBytes(destErc20.address));
    expect(relayTokensEvents[0].args?.leafId).to.equal(0);
    expect(relayTokensEvents[0].args?.chainId).to.equal(destinationChainId);
    expect(relayTokensEvents[0].args?.amountToReturn).to.equal(consts.amountToReturn);
    expect((relayTokensEvents[0].args?.refundAmounts as BigNumber[]).map((v) => v.toString())).to.deep.equal(
      [consts.amountToRelay, consts.amountToRelay].map((v) => v.toString())
    );
    expect(relayTokensEvents[0].args?.refundAddresses).to.deep.equal([
      addressToBytes(relayer.address),
      addressToBytes(rando.address),
    ]);
    expect(relayTokensEvents[0].args?.deferredRefunds).to.equal(false);

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
  it("Execution correctly logs deferred refunds", async function () {
    const { leaves, tree } = await constructSimpleTree(destErc20, destinationChainId);

    // Store new tree.
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // relayer refund root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Blacklist the relayer EOA to prevent it from receiving refunds. The execution should still succeed, though.
    await destErc20.setBlacklistStatus(relayer.address, true);
    await spokePool.connect(dataWorker).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // Only the non-blacklisted recipient should receive their refund.
    expect(await destErc20.balanceOf(spokePool.address)).to.equal(consts.amountHeldByPool.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(relayer.address)).to.equal(toBN(0));
    expect(await destErc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);

    // Check event that tracks deferred refunds.
    let relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    expect(relayTokensEvents[0].args?.deferredRefunds).to.equal(true);
  });

  describe("_distributeRelayerRefunds", function () {
    it("refund address length mismatch", async function () {
      await expect(
        spokePool
          .connect(dataWorker)
          .distributeRelayerRefunds(
            destinationChainId,
            toBN(1),
            [consts.amountToRelay, consts.amountToRelay, toBN(0)],
            0,
            addressToBytes(destErc20.address),
            [addressToBytes(relayer.address), addressToBytes(rando.address)]
          )
      ).to.be.revertedWith("InvalidMerkleLeaf");
    });
    describe("amountToReturn > 0", function () {
      it("calls _bridgeTokensToHubPool", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(1), [], 0, addressToBytes(destErc20.address), [])
        )
          .to.emit(spokePool, "BridgedToHubPool")
          .withArgs(toBN(1), destErc20.address);
      });
      it("emits TokensBridged", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(1), [], 0, addressToBytes(destErc20.address), [])
        )
          .to.emit(spokePool, "TokensBridged")
          .withArgs(toBN(1), destinationChainId, 0, addressToBytes(destErc20.address), dataWorker.address);
      });
    });
    describe("amountToReturn = 0", function () {
      it("does not call _bridgeTokensToHubPool", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(0), [], 0, addressToBytes(destErc20.address), [])
        ).to.not.emit(spokePool, "BridgedToHubPool");
      });
      it("does not emit TokensBridged", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(0), [], 0, addressToBytes(destErc20.address), [])
        ).to.not.emit(spokePool, "TokensBridged");
      });
    });
    describe("some refundAmounts > 0", function () {
      it("sends one Transfer per nonzero refundAmount", async function () {
        await expect(() =>
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(
              destinationChainId,
              toBN(1),
              [consts.amountToRelay, consts.amountToRelay, toBN(0)],
              0,
              addressToBytes(destErc20.address),
              [addressToBytes(relayer.address), addressToBytes(rando.address), addressToBytes(rando.address)]
            )
        ).to.changeTokenBalances(
          destErc20,
          [spokePool, relayer, rando],
          [consts.amountToRelay.mul(-2), consts.amountToRelay, consts.amountToRelay]
        );
        const transferLogCount = (await destErc20.queryFilter(destErc20.filters.Transfer(spokePool.address))).length;
        expect(transferLogCount).to.equal(2);
      });
      it("also bridges tokens to hub pool if amountToReturn > 0", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(
              destinationChainId,
              toBN(1),
              [consts.amountToRelay, consts.amountToRelay, toBN(0)],
              0,
              addressToBytes(destErc20.address),
              [addressToBytes(relayer.address), addressToBytes(rando.address), addressToBytes(rando.address)]
            )
        )
          .to.emit(spokePool, "BridgedToHubPool")
          .withArgs(toBN(1), destErc20.address);
      });
    });
    describe("Total refundAmounts > spokePool's balance", function () {
      it("Reverts and emits log", async function () {
        await expect(
          spokePool.connect(dataWorker).distributeRelayerRefunds(
            destinationChainId,
            toBN(1),
            [consts.amountHeldByPool, consts.amountToRelay], // spoke has only amountHeldByPool.
            0,
            bytes32ToAddress(destErc20.address),
            [bytes32ToAddress(relayer.address), bytes32ToAddress(rando.address)]
          )
        ).to.be.revertedWith("InsufficientSpokePoolBalanceToExecuteLeaf");

        expect((await destErc20.queryFilter(destErc20.filters.Transfer(spokePool.address))).length).to.equal(0);
      });
    });
  });
});
