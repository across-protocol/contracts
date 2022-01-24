import { expect } from "chai";
import { Contract } from "ethers";
import { waffle, ethers } from "hardhat";

import { getContractFactory } from "./utils";

import { TokenRolesEnum, ZERO_ADDRESS } from "@uma/common";

let hubPool: Contract;
let timer: Contract;
let weth: Contract;
let usdc: Contract;

describe("HubPool LiquidityProvision", function () {
  before(async function () {
    const [owner, liquidityProvider, other] = await ethers.getSigners();
    timer = await (await getContractFactory("Timer", owner)).deploy();
    weth = await (await getContractFactory("WETH9", owner)).deploy();
    usdc = await (await getContractFactory("ExpandedERC20", owner)).deploy("USD Coin", "USDC", 6);
    await usdc.addMember(TokenRolesEnum.MINTER, owner.address);

    hubPool = await (await getContractFactory("HubPool", owner)).deploy(timer.address);
  });

  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    await expect((await hubPool.callStatic.lpTokens(weth.address)).lpToken).to.equal(ZERO_ADDRESS);
    await hubPool.enableL1TokenForLiquidityProvision(weth.address, true, "Across-WETH-LP-V2", "LP");

    const lpTokenStruct = await hubPool.callStatic.lpTokens(weth.address);
    await expect(lpTokenStruct.lpToken).to.not.equal(ZERO_ADDRESS);
    await expect(lpTokenStruct.isWeth).to.equal(true);
    await expect(lpTokenStruct.isEnabled).to.equal(true);
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    expect(await hubPool.callStatic.timerAddress()).to.equal(timer.address);
  });
});
