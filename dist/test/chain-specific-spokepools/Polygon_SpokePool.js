"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const common_1 = require("@uma/common");
const constants_1 = require("../constants");
const utils_1 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, polygonSpokePool, timer, dai, weth;
let owner, relayer, rando, fxChild;
describe("Polygon Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, fxChild, rando] = await utils_1.ethers.getSigners();
    ({ weth, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    const polygonTokenBridger = await (
      await (0, utils_1.getContractFactory)("PolygonTokenBridger", { signer: owner })
    ).deploy(hubPool.address, weth.address);
    dai = await (await (0, utils_1.getContractFactory)("PolygonERC20Test", owner)).deploy();
    await dai.addMember(common_1.TokenRolesEnum.MINTER, owner.address);
    polygonSpokePool = await (
      await (0, utils_1.getContractFactory)("Polygon_SpokePool", { signer: owner })
    ).deploy(polygonTokenBridger.address, owner.address, hubPool.address, weth.address, fxChild.address, timer.address);
    await (0, utils_1.seedContract)(polygonSpokePool, relayer, [dai], weth, constants_1.amountHeldByPool);
  });
  it("Only correct caller can set the cross domain admin", async function () {
    const setCrossDomainAdminData = polygonSpokePool.interface.encodeFunctionData("setCrossDomainAdmin", [
      rando.address,
    ]);
    // Wrong rootMessageSender address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setCrossDomainAdminData)
    ).to.be.reverted;
    // Wrong calling address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setCrossDomainAdminData)
    ).to.be.reverted;
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setCrossDomainAdminData);
    (0, utils_1.expect)(await polygonSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });
  it("Only correct caller can set the hub pool address", async function () {
    const setHubPoolData = polygonSpokePool.interface.encodeFunctionData("setHubPool", [rando.address]);
    // Wrong rootMessageSender address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setHubPoolData)
    ).to.be.reverted;
    // Wrong calling address.
    await (0, utils_1.expect)(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setHubPoolData))
      .to.be.reverted;
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setHubPoolData);
    (0, utils_1.expect)(await polygonSpokePool.hubPool()).to.equal(rando.address);
  });
  it("Only correct caller can set the quote time buffer", async function () {
    const setDepositQuoteTimeBufferData = polygonSpokePool.interface.encodeFunctionData("setDepositQuoteTimeBuffer", [
      12345,
    ]);
    // Wrong rootMessageSender address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setDepositQuoteTimeBufferData)
    ).to.be.reverted;
    // Wrong calling address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setDepositQuoteTimeBufferData)
    ).to.be.reverted;
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setDepositQuoteTimeBufferData);
    (0, utils_1.expect)(await polygonSpokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });
  it("Only correct caller can initialize a relayer refund", async function () {
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      constants_1.mockTreeRoot,
      constants_1.mockTreeRoot,
    ]);
    // Wrong rootMessageSender address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, relayRootBundleData)
    ).to.be.reverted;
    // Wrong calling address.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, relayRootBundleData)
    ).to.be.reverted;
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);
    (0, utils_1.expect)((await polygonSpokePool.rootBundles(0)).slowRelayRoot).to.equal(constants_1.mockTreeRoot);
    (0, utils_1.expect)((await polygonSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(constants_1.mockTreeRoot);
  });
  it("Bridge tokens to hub pool correctly sends tokens through the PolygonTokenBridger", async function () {
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleRelayerRefundTree)(
      dai.address,
      await polygonSpokePool.callStatic.chainId()
    );
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      constants_1.mockTreeRoot,
    ]);
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);
    const bridger = await polygonSpokePool.polygonTokenBridger();
    // Checks that there's a burn event from the bridger.
    await (0, utils_1.expect)(
      polygonSpokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    )
      .to.emit(dai, "Transfer")
      .withArgs(bridger, common_1.ZERO_ADDRESS, constants_1.amountToReturn);
  });
  it("PolygonTokenBridger retrieves and unwraps tokens correctly", async function () {
    const polygonTokenBridger = await (
      await (0, utils_1.getContractFactory)("PolygonTokenBridger", { signer: owner })
    ).deploy(hubPool.address, weth.address);
    await (0, utils_1.expect)(() =>
      owner.sendTransaction({ to: polygonTokenBridger.address, value: (0, utils_1.toWei)("1") })
    ).to.changeTokenBalance(weth, polygonTokenBridger, (0, utils_1.toWei)("1"));
    await (0, utils_1.expect)(() => polygonTokenBridger.connect(owner).retrieve(weth.address)).to.changeTokenBalances(
      weth,
      [polygonTokenBridger, hubPool],
      [(0, utils_1.toWei)("1").mul(-1), (0, utils_1.toWei)("1")]
    );
  });
});
