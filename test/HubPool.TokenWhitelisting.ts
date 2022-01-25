import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { ZERO_ADDRESS } from "@uma/common";
import { getContractFactory } from "./utils";
import { deployHubPoolTestHelperContracts } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, owner: any, liquidityProvider: any, other: any;

describe("HubPool Token Whitelisting", function () {
  before(async function () {
    [owner, liquidityProvider, other] = await ethers.getSigners();
    ({ weth, hubPool } = await deployHubPoolTestHelperContracts(owner));
  });

  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    await expect((await hubPool.callStatic.lpTokens(weth.address)).lpToken).to.equal(ZERO_ADDRESS);
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);

    const lpTokenStruct = await hubPool.callStatic.lpTokens(weth.address);
    await expect(lpTokenStruct.lpToken).to.not.equal(ZERO_ADDRESS);
    await expect(lpTokenStruct.isEnabled).to.equal(true);

    const lpToken = await (await getContractFactory("ExpandedERC20", owner)).attach(lpTokenStruct.lpToken);
    await expect(await lpToken.callStatic.symbol()).to.equal("Av2-WETH-LP");
    await expect(await lpToken.callStatic.name()).to.equal("Across Wrapped Ether LP Token");
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can disable L1 Tokens for liquidity provision", async function () {
    await hubPool.disableL1TokenForLiquidityProvision(weth.address);
    await expect((await hubPool.callStatic.lpTokens(weth.address)).isEnabled).to.equal(false);
  });
  it("Only owner can disable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).disableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
});
