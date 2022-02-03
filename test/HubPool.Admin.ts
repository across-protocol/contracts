import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { ZERO_ADDRESS } from "@uma/common";
import { getContractFactory, SignerWithAddress, createRandomBytes32, seedWallet } from "./utils";
import { destinationChainId, bondAmount } from "./constants";
import { hubPoolFixture } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("HubPool Admin functions", function () {
  beforeEach(async function () {
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
    await expect(hubPool.whitelistRoute(weth.address, usdc.address, destinationChainId))
      .to.emit(hubPool, "WhitelistRoute")
      .withArgs(weth.address, destinationChainId, usdc.address);
    expect(await hubPool.whitelistedRoutes(weth.address, destinationChainId)).to.equal(usdc.address);
  });

  it("Can change the bond token and amount", async function () {
    expect(await hubPool.callStatic.bondToken()).to.equal(weth.address); // Default set in the fixture.
    expect(await hubPool.callStatic.bondAmount()).to.equal(bondAmount); // Default set in the fixture.

    // Set the bond token and amount to 1000 USDC
    const newBondAmount = ethers.utils.parseUnits("1000", 6); // set to 1000e6, i.e 1000 USDC.
    await hubPool.setBond(usdc.address, newBondAmount);
    expect(await hubPool.callStatic.bondToken()).to.equal(usdc.address); // New Address.
    expect(await hubPool.callStatic.bondAmount()).to.equal(newBondAmount); // New Bond amount.
  });
  it("Can not change the bond token and amount during a pending refund", async function () {
    await seedWallet(owner, [], weth, bondAmount);
    await weth.approve(hubPool.address, bondAmount);
    await hubPool.initiateRelayerRefund([1, 2, 3], 5, createRandomBytes32(), createRandomBytes32());
    await expect(hubPool.setBond(usdc.address, "1")).to.be.revertedWith("Active request has unclaimed leafs");
  });
});
