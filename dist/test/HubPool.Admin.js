"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const utils_2 = require("./utils");
const constants_1 = require("./constants");
const constants_2 = require("./constants");
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
let hubPool, weth, usdc, mockSpoke, mockAdapter, identifierWhitelist;
let owner, other;
describe("HubPool Admin functions", function () {
  beforeEach(async function () {
    [owner, other] = await utils_2.ethers.getSigners();
    ({ weth, hubPool, usdc, mockAdapter, mockSpoke, identifierWhitelist } = await (0,
    HubPool_Fixture_1.hubPoolFixture)());
  });
  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    (0, utils_1.expect)((await hubPool.callStatic.pooledTokens(weth.address)).lpToken).to.equal(
      constants_1.zeroAddress
    );
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);
    const pooledTokenStruct = await hubPool.callStatic.pooledTokens(weth.address);
    (0, utils_1.expect)(pooledTokenStruct.lpToken).to.not.equal(constants_1.zeroAddress);
    (0, utils_1.expect)(pooledTokenStruct.isEnabled).to.equal(true);
    (0, utils_1.expect)(pooledTokenStruct.lastLpFeeUpdate).to.equal(Number(await hubPool.getCurrentTime()));
    const lpToken = await (
      await (0, utils_1.getContractFactory)("ExpandedERC20", owner)
    ).attach(pooledTokenStruct.lpToken);
    (0, utils_1.expect)(await lpToken.callStatic.symbol()).to.equal("Av2-WETH-LP");
    (0, utils_1.expect)(await lpToken.callStatic.name()).to.equal("Across Wrapped Ether LP Token");
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    await (0, utils_1.expect)(hubPool.connect(other).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can disable L1 Tokens for liquidity provision", async function () {
    await hubPool.disableL1TokenForLiquidityProvision(weth.address);
    (0, utils_1.expect)((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(false);
  });
  it("Only owner can disable L1 Tokens for liquidity provision", async function () {
    await (0, utils_1.expect)(hubPool.connect(other).disableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can whitelist route for deposits and rebalances", async function () {
    await hubPool.setCrossChainContracts(constants_1.destinationChainId, mockAdapter.address, mockSpoke.address);
    await (0, utils_1.expect)(
      hubPool.whitelistRoute(constants_1.originChainId, constants_1.destinationChainId, weth.address, usdc.address)
    )
      .to.emit(hubPool, "WhitelistRoute")
      .withArgs(constants_1.originChainId, constants_1.destinationChainId, weth.address, usdc.address);
    (0, utils_1.expect)(
      await hubPool.whitelistedRoute(constants_1.originChainId, weth.address, constants_1.destinationChainId)
    ).to.equal(usdc.address);
  });
  it("Can change the bond token and amount", async function () {
    (0, utils_1.expect)(await hubPool.callStatic.bondToken()).to.equal(weth.address); // Default set in the fixture.
    (0, utils_1.expect)(await hubPool.callStatic.bondAmount()).to.equal(
      constants_1.bondAmount.add(constants_2.finalFee)
    ); // Default set in the fixture.
    // Set the bond token and amount to 1000 USDC
    const newBondAmount = utils_2.ethers.utils.parseUnits("1000", 6); // set to 1000e6, i.e 1000 USDC.
    await hubPool.setBond(usdc.address, newBondAmount);
    (0, utils_1.expect)(await hubPool.callStatic.bondToken()).to.equal(usdc.address); // New Address.
    (0, utils_1.expect)(await hubPool.callStatic.bondAmount()).to.equal(newBondAmount.add(constants_2.finalFeeUsdc)); // New Bond amount.
  });
  it("Can not change the bond token and amount during a pending refund", async function () {
    await (0, utils_1.seedWallet)(owner, [], weth, constants_2.totalBond);
    await weth.approve(hubPool.address, constants_2.totalBond);
    await hubPool.proposeRootBundle(
      [1, 2, 3],
      5,
      constants_1.mockTreeRoot,
      constants_1.mockTreeRoot,
      constants_2.mockSlowRelayRoot
    );
    await (0, utils_1.expect)(hubPool.setBond(usdc.address, "1")).to.be.revertedWith("proposal has unclaimed leafs");
  });
  it("Cannot change bond token to unwhitelisted token", async function () {
    await (0, utils_1.expect)(hubPool.setBond((0, utils_2.randomAddress)(), "1")).to.be.revertedWith(
      "Not on whitelist"
    );
  });
  it("Only owner can set bond", async function () {
    await (0, utils_1.expect)(hubPool.connect(other).setBond(usdc.address, "1")).to.be.reverted;
  });
  it("Set identifier", async function () {
    const identifier = (0, utils_2.utf8ToHex)("TEST_ID");
    await identifierWhitelist.addSupportedIdentifier(identifier);
    await hubPool.connect(owner).setIdentifier(identifier);
    (0, utils_1.expect)(await hubPool.identifier()).to.equal(identifier);
  });
  it("Only owner can set identifier", async function () {
    const identifier = (0, utils_2.utf8ToHex)("TEST_ID");
    await identifierWhitelist.addSupportedIdentifier(identifier);
    await (0, utils_1.expect)(hubPool.connect(other).setIdentifier(identifier)).to.be.reverted;
  });
  it("Only whitelisted identifiers allowed", async function () {
    const identifier = (0, utils_2.utf8ToHex)("TEST_ID");
    await (0, utils_1.expect)(hubPool.connect(owner).setIdentifier(identifier)).to.be.revertedWith(
      "Identifier not supported"
    );
  });
  it("Set liveness", async function () {
    const newLiveness = 1000000;
    await hubPool.connect(owner).setLiveness(newLiveness);
    await (0, utils_1.expect)(await hubPool.liveness()).to.equal(newLiveness);
  });
  it("Liveness too short", async function () {
    await (0, utils_1.expect)(hubPool.connect(owner).setLiveness(599)).to.be.revertedWith("Liveness too short");
  });
  it("Only owner can set liveness", async function () {
    await (0, utils_1.expect)(hubPool.connect(other).setLiveness(1000000)).to.be.reverted;
  });
});
