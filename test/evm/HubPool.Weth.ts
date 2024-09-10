import { toWei, toBN, SignerWithAddress, expect, Contract, ethers } from "../../utils/utils";
import { hubPoolFixture } from "./fixtures/HubPool.Fixture";

let hubPool: Contract, weth: Contract;
let owner: SignerWithAddress;

describe("HubPool Correctly Handles ETH", function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, hubPool } = await hubPoolFixture());
  });

  it("Correctly wraps ETH to WETH when ETH is dropped on the contract", async function () {
    // Drop ETH on the hubPool and check that hubPool wraps it.
    expect(await weth.balanceOf(hubPool.address)).to.equal(toBN(0));

    // Drop ETH on the contract. Check it wraps it to WETH.
    await owner.sendTransaction({ to: hubPool.address, value: toWei(1) });

    expect(await weth.balanceOf(hubPool.address)).to.equal(toWei(1));
  });
});
