"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const constants_1 = require("../constants");
const utils_1 = require("../utils");
const utils_2 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, optimismSpokePool, timer, dai, weth;
let l2Dai;
let owner, relayer, rando;
let crossDomainMessenger, l2StandardBridge, l2Weth;
describe("Optimism Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await utils_1.ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    // Create the fake at the optimism cross domain messenger and l2StandardBridge pre-deployment addresses.
    crossDomainMessenger = await (0, utils_1.createFake)(
      "L2CrossDomainMessenger",
      "0x4200000000000000000000000000000000000007"
    );
    l2StandardBridge = await (0, utils_1.createFake)("L2StandardBridge", "0x4200000000000000000000000000000000000010");
    // Set l2Weth to the address deployed on the optimism predeploy.
    l2Weth = await (0, utils_1.createFake)("WETH9", "0x4200000000000000000000000000000000000006");
    await utils_2.hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: (0, utils_1.toWei)("1") });
    optimismSpokePool = await (
      await (0, utils_2.getContractFactory)("Optimism_SpokePool", { signer: owner })
    ).deploy(owner.address, hubPool.address, timer.address);
    await (0, utils_2.seedContract)(optimismSpokePool, relayer, [dai], weth, constants_1.amountHeldByPool);
  });
  it("Only cross domain owner can set l1GasLimit", async function () {
    await (0, utils_1.expect)(optimismSpokePool.setL1GasLimit(1337)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setL1GasLimit(1337);
    (0, utils_1.expect)(await optimismSpokePool.l1Gas()).to.equal(1337);
  });
  it("Only cross domain owner can enable a route", async function () {
    await (0, utils_1.expect)(optimismSpokePool.setEnableRoute(l2Dai, 1, true)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setEnableRoute(l2Dai, 1, true);
    (0, utils_1.expect)(await optimismSpokePool.enabledDepositRoutes(l2Dai, 1)).to.equal(true);
  });
  it("Only cross domain owner can set the cross domain admin", async function () {
    await (0, utils_1.expect)(optimismSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setCrossDomainAdmin(rando.address);
    (0, utils_1.expect)(await optimismSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });
  it("Only cross domain owner can set the hub pool address", async function () {
    await (0, utils_1.expect)(optimismSpokePool.setHubPool(rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setHubPool(rando.address);
    (0, utils_1.expect)(await optimismSpokePool.hubPool()).to.equal(rando.address);
  });
  it("Only cross domain owner can set the quote time buffer", async function () {
    await (0, utils_1.expect)(optimismSpokePool.setDepositQuoteTimeBuffer(12345)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setDepositQuoteTimeBuffer(12345);
    (0, utils_1.expect)(await optimismSpokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });
  it("Only cross domain owner can initialize a relayer refund", async function () {
    await (0, utils_1.expect)(optimismSpokePool.relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot)).to
      .be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool
      .connect(crossDomainMessenger.wallet)
      .relayRootBundle(constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    (0, utils_1.expect)((await optimismSpokePool.rootBundles(0)).slowRelayRoot).to.equal(constants_1.mockTreeRoot);
    (0, utils_1.expect)((await optimismSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(constants_1.mockTreeRoot);
  });
  it("Bridge tokens to hub pool correctly calls the Standard L2 Bridge for ERC20", async function () {
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleRelayerRefundTree)(
      l2Dai,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool
      .connect(crossDomainMessenger.wallet)
      .relayRootBundle(tree.getHexRoot(), constants_1.mockTreeRoot);
    await optimismSpokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    (0, utils_1.expect)(l2StandardBridge.withdrawTo).to.have.been.calledOnce;
    (0, utils_1.expect)(l2StandardBridge.withdrawTo).to.have.been.calledWith(
      l2Dai,
      hubPool.address,
      constants_1.amountToReturn,
      5000000,
      "0x"
    );
  });
  it("Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH, including unwrap", async function () {
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleRelayerRefundTree)(
      l2Weth.address,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool
      .connect(crossDomainMessenger.wallet)
      .relayRootBundle(tree.getHexRoot(), constants_1.mockTreeRoot);
    await optimismSpokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    // When sending l2Weth we should see two differences from the previous test: 1) there should be a call to l2WETH to
    // unwrap l2WETH to l2ETH. 2) the address in the l2StandardBridge that is withdrawn should no longer be l2WETH but
    // switched to l2ETH as this is what is sent over the canonical Optimism bridge when sending ETH.
    (0, utils_1.expect)(l2Weth.withdraw).to.have.been.calledOnce;
    (0, utils_1.expect)(l2Weth.withdraw).to.have.been.calledWith(constants_1.amountToReturn);
    (0, utils_1.expect)(l2StandardBridge.withdrawTo).to.have.been.calledOnce;
    const l2Eth = "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000";
    (0, utils_1.expect)(l2StandardBridge.withdrawTo).to.have.been.calledWith(
      l2Eth,
      hubPool.address,
      constants_1.amountToReturn,
      5000000,
      "0x"
    );
  });
});
