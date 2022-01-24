import { expect } from "chai";
import { Contract } from "ethers";
import { deployContract, MockProvider } from "ethereum-waffle";
import { getContract } from "./utils";

let hubPool: Contract;
let timer: Contract;

describe("HubPool LiquidityProvision", async function () {
  const [owner] = new MockProvider().getWallets();

  before(async function () {
    timer = await deployContract(owner, await getContract("Timer"));

    hubPool = await deployContract(owner, await getContract("HubPool"), [timer.address]);
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    expect(await hubPool.callStatic.timerAddress()).to.equal(timer.address);
  });
});
