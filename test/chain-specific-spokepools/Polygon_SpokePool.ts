import { TokenRolesEnum, ZERO_ADDRESS } from "@uma/common";
import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, SignerWithAddress, getContractFactory, seedContract, toWei } from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, polygonSpokePool: Contract, timer: Contract, dai: Contract, weth: Contract;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, fxChild: SignerWithAddress;

describe("Polygon Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, fxChild, rando] = await ethers.getSigners();
    ({ weth, hubPool, timer } = await hubPoolFixture());

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address);

    dai = await (await getContractFactory("PolygonERC20Test", owner)).deploy();
    await dai.addMember(TokenRolesEnum.MINTER, owner.address);

    polygonSpokePool = await (
      await getContractFactory("Polygon_SpokePool", owner)
    ).deploy(polygonTokenBridger.address, owner.address, hubPool.address, weth.address, fxChild.address, timer.address);

    await seedContract(polygonSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only correct caller can set the cross domain admin", async function () {
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

  it("Only correct caller can set the quote time buffer", async function () {
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
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
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

    expect((await polygonSpokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await polygonSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Bridge tokens to hub pool correctly sends tokens through the PolygonTokenBridger", async function () {
    const { leafs, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await polygonSpokePool.callStatic.chainId()
    );
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);
    const bridger = await polygonSpokePool.polygonTokenBridger();

    // Checks that there's a burn event from the bridger.
    await expect(polygonSpokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0])))
      .to.emit(dai, "Transfer")
      .withArgs(bridger, ZERO_ADDRESS, amountToReturn);
  });

  it("PolygonTokenBridger retrieves and unwraps tokens correctly", async function () {
    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, weth.address);

    await expect(() =>
      owner.sendTransaction({ to: polygonTokenBridger.address, value: toWei("1") })
    ).to.changeTokenBalance(weth, polygonTokenBridger, toWei("1"));

    await expect(() => polygonTokenBridger.connect(owner).retrieve(weth.address)).to.changeTokenBalances(
      weth,
      [polygonTokenBridger, hubPool],
      [toWei("1").mul(-1), toWei("1")]
    );
  });
});
