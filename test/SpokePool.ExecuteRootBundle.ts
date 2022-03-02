import { SignerWithAddress, seedContract, toBN, expect, Contract, ethers } from "./utils";
import * as consts from "./constants";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { buildRelayerRefundTree, buildRelayerRefundLeafs } from "./MerkleLib.utils";

let spokePool: Contract, destErc20: Contract, weth: Contract;
let dataWorker: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let destinationChainId: number;

async function constructSimpleTree(l2Token: Contract, destinationChainId: number) {
  const leafs = buildRelayerRefundLeafs(
    [destinationChainId, destinationChainId], // Destination chain ID.
    [consts.amountToReturn, toBN(0)], // amountToReturn.
    [l2Token.address, l2Token.address], // l2Token.
    [[relayer.address, rando.address], []], // refundAddresses.
    [[consts.amountToRelay, consts.amountToRelay], []] // refundAmounts.
  );
  const leafsRefundAmount = leafs
    .map((leaf) => leaf.refundAmounts.reduce((bn1, bn2) => bn1.add(bn2), toBN(0)))
    .reduce((bn1, bn2) => bn1.add(bn2), toBN(0));
  const tree = await buildRelayerRefundTree(leafs);

  return { leafs, leafsRefundAmount, tree };
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
    const { leafs, leafsRefundAmount, tree } = await constructSimpleTree(destErc20, destinationChainId);

    // Store new tree.
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // relayer refund root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Distribute the first leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));

    // Relayers should be refunded
    expect(await destErc20.balanceOf(spokePool.address)).to.equal(consts.amountHeldByPool.sub(leafsRefundAmount));
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToRelay);
    expect(await destErc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);

    // Check events.
    let relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    expect(relayTokensEvents[0].args?.l2TokenAddress).to.equal(destErc20.address);
    expect(relayTokensEvents[0].args?.leafId).to.equal(0);
    expect(relayTokensEvents[0].args?.chainId).to.equal(destinationChainId);
    expect(relayTokensEvents[0].args?.amountToReturn).to.equal(consts.amountToReturn);
    expect(relayTokensEvents[0].args?.refundAmounts).to.deep.equal([consts.amountToRelay, consts.amountToRelay]);
    expect(relayTokensEvents[0].args?.refundAddresses).to.deep.equal([relayer.address, rando.address]);
    expect(relayTokensEvents[0].args?.caller).to.equal(dataWorker.address);

    // Should emit TokensBridged event if amountToReturn is positive.
    let tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    expect(tokensBridgedEvents.length).to.equal(1);

    // Does not attempt to bridge tokens if amountToReturn is 0. Execute a leaf where amountToReturn is 0.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[1], tree.getHexProof(leafs[1]));
    // Show that a second DistributedRelayRefund event was emitted but not a second TokensBridged event.
    relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    expect(relayTokensEvents.length).to.equal(2);
    tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    expect(tokensBridgedEvents.length).to.equal(1);
  });

  it("Execution rejects invalid leaf, tree, proof combinations", async function () {
    const { leafs, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Take the valid root but change some element within it. This will change the hash of the leaf
    // and as such the contract should reject it for not being included within the merkle tree for the valid proof.
    const badLeaf = { ...leafs[0], chainId: 13371 };
    await expect(spokePool.connect(dataWorker).executeRelayerRefundRoot(0, badLeaf, tree.getHexProof(leafs[0]))).to.be
      .reverted;

    // Reverts if the distribution root index is incorrect.
    await expect(spokePool.connect(dataWorker).executeRelayerRefundRoot(1, leafs[0], tree.getHexProof(leafs[0]))).to.be
      .reverted;
  });
  it("Cannot refund leaf with chain ID for another network", async function () {
    // Create tree for another chain ID
    const { leafs, tree } = await constructSimpleTree(destErc20, 13371);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // Root is valid and leaf is contained in tree, but chain ID doesn't match pool's chain ID.
    await expect(spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))).to.be
      .reverted;
  });
  it("Execution rejects double claimed leafs", async function () {
    const { leafs, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );

    // First claim should be fine. Second claim should be reverted as you cant double claim a leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    await expect(spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))).to.be
      .reverted;
  });
});
