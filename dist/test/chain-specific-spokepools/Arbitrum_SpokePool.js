"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const constants_1 = require("../constants");
const utils_1 = require("../utils");
const utils_2 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, arbitrumSpokePool, timer, dai, weth;
let l2Weth, l2Dai, crossDomainAliasAddress;
let owner, relayer, rando, crossDomainAlias;
let l2GatewayRouter;
describe("Arbitrum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await utils_1.ethers.getSigners();
    ({ weth, l2Weth, dai, l2Dai, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    // Create an alias for the Owner. Impersonate the account. Crate a signer for it and send it ETH.
    crossDomainAliasAddress = (0, utils_2.avmL1ToL2Alias)(owner.address);
    await utils_2.hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainAliasAddress],
    });
    crossDomainAlias = await utils_1.ethers.getSigner(crossDomainAliasAddress);
    await owner.sendTransaction({ to: crossDomainAliasAddress, value: (0, utils_1.toWei)("1") });
    l2GatewayRouter = await (0, utils_1.createFake)("L2GatewayRouter");
    arbitrumSpokePool = await (
      await (0, utils_2.getContractFactory)("Arbitrum_SpokePool", { signer: owner })
    ).deploy(l2GatewayRouter.address, owner.address, hubPool.address, l2Weth, timer.address);
    await (0, utils_2.seedContract)(arbitrumSpokePool, relayer, [dai], weth, constants_1.amountHeldByPool);
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, dai.address);
  });
  it("Only cross domain owner can set L2GatewayRouter", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.setL2GatewayRouter(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setL2GatewayRouter(rando.address);
    (0, utils_1.expect)(await arbitrumSpokePool.l2GatewayRouter()).to.equal(rando.address);
  });
  it("Only cross domain owner can enable a route", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.setEnableRoute(l2Dai, 1, true)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setEnableRoute(l2Dai, 1, true);
    (0, utils_1.expect)(await arbitrumSpokePool.enabledDepositRoutes(l2Dai, 1)).to.equal(true);
  });
  it("Only cross domain owner can whitelist a token pair", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.whitelistToken(l2Dai, dai.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, dai.address);
    (0, utils_1.expect)(await arbitrumSpokePool.whitelistedTokens(l2Dai)).to.equal(dai.address);
  });
  it("Only cross domain owner can set the cross domain admin", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setCrossDomainAdmin(rando.address);
    (0, utils_1.expect)(await arbitrumSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });
  it("Only cross domain owner can set the hub pool address", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.setHubPool(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setHubPool(rando.address);
    (0, utils_1.expect)(await arbitrumSpokePool.hubPool()).to.equal(rando.address);
  });
  it("Only cross domain owner can set the quote time buffer", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.setDepositQuoteTimeBuffer(12345)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setDepositQuoteTimeBuffer(12345);
    (0, utils_1.expect)(await arbitrumSpokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });
  it("Only cross domain owner can initialize a relayer refund", async function () {
    await (0, utils_1.expect)(arbitrumSpokePool.relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot)).to
      .be.reverted;
    await arbitrumSpokePool
      .connect(crossDomainAlias)
      .relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    (0, utils_1.expect)((await arbitrumSpokePool.rootBundles(0)).slowRelayRoot).to.equal(constants_1.mockTreeRoot);
    (0, utils_1.expect)((await arbitrumSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(constants_1.mockTreeRoot);
  });
  it("Bridge tokens to hub pool correctly calls the Standard L2 Gateway router", async function () {
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleRelayerRefundTree)(
      l2Dai,
      await arbitrumSpokePool.callStatic.chainId()
    );
    await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), constants_1.mockTreeRoot);
    await arbitrumSpokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    // outboundTransfer is overloaded in the arbitrum gateway. Define the interface to check the method is called.
    const functionKey = "outboundTransfer(address,address,uint256,bytes)";
    (0, utils_1.expect)(l2GatewayRouter[functionKey]).to.have.been.calledOnce;
    (0, utils_1.expect)(l2GatewayRouter[functionKey]).to.have.been.calledWith(
      dai.address,
      hubPool.address,
      constants_1.amountToReturn,
      "0x"
    );
  });
});
