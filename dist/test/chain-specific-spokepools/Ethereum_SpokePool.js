"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const constants_1 = require("../constants");
const utils_1 = require("../utils");
const utils_2 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, spokePool, timer, dai, weth;
let owner, relayer, rando;
describe("Ethereum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await utils_1.ethers.getSigners();
    ({ weth, dai, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    spokePool = await (
      await (0, utils_2.getContractFactory)("Ethereum_SpokePool", { signer: owner })
    ).deploy(hubPool.address, weth.address, timer.address);
    // Seed spoke pool with tokens that it should transfer to the hub pool
    // via the _bridgeTokensToHubPool() internal call.
    await (0, utils_2.seedContract)(spokePool, relayer, [dai], weth, constants_1.amountHeldByPool);
  });
  it("Only owner can set the cross domain admin", async function () {
    await (0, utils_1.expect)(spokePool.connect(rando).setCrossDomainAdmin(rando.address)).to.be.reverted;
    await spokePool.connect(owner).setCrossDomainAdmin(rando.address);
    (0, utils_1.expect)(await spokePool.crossDomainAdmin()).to.equal(rando.address);
  });
  it("Only owner can enable a route", async function () {
    await (0, utils_1.expect)(spokePool.connect(rando).setEnableRoute(dai.address, 1, true)).to.be.reverted;
    await spokePool.connect(owner).setEnableRoute(dai.address, 1, true);
    (0, utils_1.expect)(await spokePool.enabledDepositRoutes(dai.address, 1)).to.equal(true);
  });
  it("Only owner can set the hub pool address", async function () {
    await (0, utils_1.expect)(spokePool.connect(rando).setHubPool(rando.address)).to.be.reverted;
    await spokePool.connect(owner).setHubPool(rando.address);
    (0, utils_1.expect)(await spokePool.hubPool()).to.equal(rando.address);
  });
  it("Only owner can set the quote time buffer", async function () {
    await (0, utils_1.expect)(spokePool.connect(rando).setDepositQuoteTimeBuffer(12345)).to.be.reverted;
    await spokePool.connect(owner).setDepositQuoteTimeBuffer(12345);
    (0, utils_1.expect)(await spokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });
  it("Only owner can initialize a relayer refund", async function () {
    await (0, utils_1.expect)(
      spokePool.connect(rando).relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot)
    ).to.be.reverted;
    await spokePool.connect(owner).relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    (0, utils_1.expect)((await spokePool.rootBundles(0)).slowRelayRoot).to.equal(constants_1.mockTreeRoot);
    (0, utils_1.expect)((await spokePool.rootBundles(0)).relayerRefundRoot).to.equal(constants_1.mockTreeRoot);
  });
  it("Bridge tokens to hub pool correctly sends tokens to hub pool", async function () {
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleRelayerRefundTree)(
      dai.address,
      await spokePool.callStatic.chainId()
    );
    await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), constants_1.mockTreeRoot);
    await (0, utils_1.expect)(() =>
      spokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    ).to.changeTokenBalances(
      dai,
      [spokePool, hubPool],
      [constants_1.amountToReturn.mul(-1), constants_1.amountToReturn]
    );
  });
});
