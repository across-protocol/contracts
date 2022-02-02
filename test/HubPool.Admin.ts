import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { ZERO_ADDRESS } from "@uma/common";
import { getContractFactory, SignerWithAddress } from "./utils";
import { depositDestinationChainId } from "./constants";
import { hubPoolFixture } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("HubPool Admin functions", function () {
  before(async function () {
    [owner, other] = await ethers.getSigners();
    ({ weth, hubPool, usdc } = await hubPoolFixture());
  });

  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    expect((await hubPool.callStatic.lpTokens(weth.address)).lpToken).to.equal(ZERO_ADDRESS);
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);

    const lpTokenStruct = await hubPool.callStatic.lpTokens(weth.address);
    expect(lpTokenStruct.lpToken).to.not.equal(ZERO_ADDRESS);
    expect(lpTokenStruct.isEnabled).to.equal(true);

    const lpToken = await (await getContractFactory("ExpandedERC20", owner)).attach(lpTokenStruct.lpToken);
    expect(await lpToken.callStatic.symbol()).to.equal("Av2-WETH-LP");
    expect(await lpToken.callStatic.name()).to.equal("Across Wrapped Ether LP Token");
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can disable L1 Tokens for liquidity provision", async function () {
    await hubPool.disableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.lpTokens(weth.address)).isEnabled).to.equal(false);
  });
  it("Only owner can disable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).disableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can whitelist route for deposits and rebalances", async function () {
    await expect(hubPool.whitelistRoute(weth.address, usdc.address, depositDestinationChainId))
      .to.emit(hubPool, "WhitelistRoute")
      .withArgs(weth.address, depositDestinationChainId, usdc.address);
    expect(await hubPool.whitelistedRoutes(weth.address, depositDestinationChainId)).to.equal(usdc.address);
  });
});
