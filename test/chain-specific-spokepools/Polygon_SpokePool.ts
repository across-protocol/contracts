import { TokenRolesEnum, ZERO_ADDRESS } from "@uma/common";
import { mockTreeRoot, amountToReturn, amountHeldByPool, rootBundleId } from "../constants";
import {
  ethers,
  expect,
  Contract,
  SignerWithAddress,
  getContractFactory,
  seedContract,
  toWei,
  randomBigNumber,
  seedWallet,
} from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, polygonSpokePool: Contract, timer: Contract, dai: Contract, weth: Contract, l2Dai: string;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, fxChild: SignerWithAddress;

describe("Polygon Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, fxChild, rando] = await ethers.getSigners();
    ({ weth, hubPool, timer, l2Dai } = await hubPoolFixture());

    // The spoke pool exists on l2, so add a random chainId for L1 to ensure that the L2's block.chainid will not match.
    const l1ChainId = randomBigNumber();
    const l2ChainId = await owner.getChainId();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address, l1ChainId, l2ChainId);

    dai = await (await getContractFactory("PolygonERC20Test", owner)).deploy();
    await dai.addMember(TokenRolesEnum.MINTER, owner.address);

    polygonSpokePool = await (
      await getContractFactory("Polygon_SpokePool", owner)
    ).deploy(polygonTokenBridger.address, owner.address, hubPool.address, weth.address, fxChild.address, timer.address);

    await seedContract(polygonSpokePool, relayer, [dai], weth, amountHeldByPool);
    await seedWallet(owner, [], weth, toWei("1"));
  });

  it("Only correct caller can set the cross domain admin", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;

    const setCrossDomainAdminData = polygonSpokePool.interface.encodeFunctionData("setCrossDomainAdmin", [
      rando.address,
    ]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setCrossDomainAdminData)).to
      .be.reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setCrossDomainAdminData)).to
      .be.reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setCrossDomainAdminData);
    expect(await polygonSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Only correct caller can set the hub pool address", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setHubPool(rando.address)).to.be.reverted;

    const setHubPoolData = polygonSpokePool.interface.encodeFunctionData("setHubPool", [rando.address]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setHubPoolData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setHubPoolData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setHubPoolData);
    expect(await polygonSpokePool.hubPool()).to.equal(rando.address);
  });

  it("Only correct caller can enable a route", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setEnableRoute(l2Dai, 1, true)).to.be.reverted;

    const setEnableRouteData = polygonSpokePool.interface.encodeFunctionData("setEnableRoute", [l2Dai, 1, true]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setEnableRouteData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setEnableRouteData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setEnableRouteData);
    expect(await polygonSpokePool.enabledDepositRoutes(l2Dai, 1)).to.equal(true);
  });

  it("Only correct caller can set the quote time buffer", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setDepositQuoteTimeBuffer(12345)).to.be.reverted;

    const setDepositQuoteTimeBufferData = polygonSpokePool.interface.encodeFunctionData("setDepositQuoteTimeBuffer", [
      12345,
    ]);

    // Wrong rootMessageSender address.
    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setDepositQuoteTimeBufferData)
    ).to.be.reverted;

    // Wrong calling address.
    await expect(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setDepositQuoteTimeBufferData)
    ).to.be.reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setDepositQuoteTimeBufferData);
    expect(await polygonSpokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });

  it("Only correct caller can initialize a relayer refund", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.relayRootBundle(rootBundleId, mockTreeRoot, mockTreeRoot)).to.be.reverted;

    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      rootBundleId,
      mockTreeRoot,
      mockTreeRoot,
    ]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, relayRootBundleData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, relayRootBundleData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    expect((await polygonSpokePool.rootBundles(rootBundleId)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await polygonSpokePool.rootBundles(rootBundleId)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Cannot re-enter processMessageFromRoot", async function () {
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      rootBundleId,
      mockTreeRoot,
      mockTreeRoot,
    ]);
    const processMessageFromRootData = polygonSpokePool.interface.encodeFunctionData("processMessageFromRoot", [
      0,
      owner.address,
      relayRootBundleData,
    ]);

    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, processMessageFromRootData))
      .to.be.reverted;
  });

  it("Only owner can delete a relayer refund", async function () {
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      rootBundleId,
      mockTreeRoot,
      mockTreeRoot,
    ]);

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    // Cannot call directly
    await expect(polygonSpokePool.emergencyDeleteRootBundle(rootBundleId)).to.be.reverted;

    const emergencyDeleteRelayRootBundleData = polygonSpokePool.interface.encodeFunctionData(
      "emergencyDeleteRootBundle",
      [rootBundleId]
    );

    // Wrong rootMessageSender address.
    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, emergencyDeleteRelayRootBundleData)
    ).to.be.reverted;

    // Wrong calling address.
    await expect(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, emergencyDeleteRelayRootBundleData)
    ).to.be.reverted;

    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, emergencyDeleteRelayRootBundleData)
    ).to.not.be.reverted;
    expect((await polygonSpokePool.rootBundles(rootBundleId)).slowRelayRoot).to.equal(
      ethers.utils.hexZeroPad("0x0", 32)
    );
    expect((await polygonSpokePool.rootBundles(rootBundleId)).relayerRefundRoot).to.equal(
      ethers.utils.hexZeroPad("0x0", 32)
    );
  });

  it("Bridge tokens to hub pool correctly sends tokens through the PolygonTokenBridger", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await polygonSpokePool.callStatic.chainId()
    );
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      rootBundleId,
      tree.getHexRoot(),
      mockTreeRoot,
    ]);

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);
    const bridger = await polygonSpokePool.polygonTokenBridger();

    // Checks that there's a burn event from the bridger.
    await expect(
      polygonSpokePool.connect(relayer).executeRelayerRefundLeaf(rootBundleId, leaves[0], tree.getHexProof(leaves[0]))
    )
      .to.emit(dai, "Transfer")
      .withArgs(bridger, ZERO_ADDRESS, amountToReturn);
  });

  it("PolygonTokenBridger retrieves and unwraps tokens correctly", async function () {
    const l1ChainId = await owner.getChainId();

    // Retrieve can only be performed on L1, so seed the L2 chainId with a non matching value.
    const l2ChainId = randomBigNumber();
    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address, l1ChainId, l2ChainId);

    await expect(() =>
      owner.sendTransaction({ to: polygonTokenBridger.address, value: toWei("1") })
    ).to.changeTokenBalance(weth, polygonTokenBridger, toWei("1"));

    await expect(() => polygonTokenBridger.connect(owner).retrieve(weth.address)).to.changeTokenBalances(
      weth,
      [polygonTokenBridger, hubPool],
      [toWei("1").mul(-1), toWei("1")]
    );
  });

  it("PolygonTokenBridger doesn't allow L1 actions on L2", async function () {
    // Make sure the L1 chain is different from the chainId where this is deployed.
    const l1ChainId = randomBigNumber();
    const l2ChainId = await owner.getChainId();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address, l1ChainId, l2ChainId);

    // Cannot send ETH directly into the contract on L2.
    await expect(owner.sendTransaction({ to: polygonTokenBridger.address, value: toWei("1") })).to.be.revertedWith(
      "Cannot run method on this chain"
    );

    // Cannot call retrieve on the contract on L2.
    await weth.connect(owner).transfer(polygonTokenBridger.address, toWei("1"));
    await expect(polygonTokenBridger.connect(owner).retrieve(weth.address)).to.be.revertedWith(
      "Cannot run method on this chain"
    );
  });

  it("PolygonTokenBridger doesn't allow L2 actions on L1", async function () {
    const l1ChainId = await owner.getChainId();

    // Make sure the L1 chain is different from the chainId where this is deployed.
    const l2ChainId = randomBigNumber();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address, l1ChainId, l2ChainId);

    await weth.connect(owner).approve(polygonTokenBridger.address, toWei("1"));

    // Cannot call send on the contract on L1.
    await expect(polygonTokenBridger.connect(owner).send(weth.address, toWei("1"), false)).to.be.revertedWith(
      "Cannot run method on this chain"
    );
  });
});
