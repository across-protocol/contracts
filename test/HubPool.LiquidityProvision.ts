import { expect } from "chai";
import { Contract } from "ethers";
import { waffle, ethers } from "hardhat";
const { deployContract } = waffle;

import { getContract } from "./utils";

import { TokenRolesEnum, ZERO_ADDRESS } from "@uma/common";

let hubPool: Contract;
let timer: Contract;
let l1Token1: Contract;
let l1Token2: Contract;

describe("HubPool LiquidityProvision", function () {
  before(async function () {
    const [owner, liquidityProvider, other] = await ethers.getSigners();

    console.log("owner", owner.address);
    timer = await deployContract(owner, await getContract("Timer"));
    l1Token1 = await deployContract(owner, await getContract("ExpandedERC20"), ["Wrapped Ethereum", "WETH", 18]);
    await l1Token1.addMember(TokenRolesEnum.MINTER, owner.address);
    l1Token2 = await deployContract(owner, await getContract("ExpandedERC20"), ["USD Coin", "USDC", 6]);
    await l1Token2.addMember(TokenRolesEnum.MINTER, owner.address);
    hubPool = await deployContract(owner, await getContract("HubPool"), [timer.address]);
    console.log("hubPool", hubPool.address);
  });

  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    await expect((await hubPool.callStatic.lpTokens(l1Token1.address)).lpToken).to.equal(ZERO_ADDRESS);
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    expect(await hubPool.callStatic.timerAddress()).to.equal(timer.address);
  });
});
