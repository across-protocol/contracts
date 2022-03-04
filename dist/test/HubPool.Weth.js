"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
let hubPool, weth;
let owner;
describe("HubPool Correctly Handles ETH", function () {
  beforeEach(async function () {
    [owner] = await utils_1.ethers.getSigners();
    ({ weth, hubPool } = await (0, HubPool_Fixture_1.hubPoolFixture)());
  });
  it("Correctly wraps ETH to WETH when ETH is dropped on the contract", async function () {
    // Drop ETH on the hubPool and check that hubPool wraps it.
    (0, utils_1.expect)(await weth.balanceOf(hubPool.address)).to.equal((0, utils_1.toBN)(0));
    // Drop ETH on the contract. Check it wraps it to WETH.
    await owner.sendTransaction({ to: hubPool.address, value: (0, utils_1.toWei)(1) });
    (0, utils_1.expect)(await weth.balanceOf(hubPool.address)).to.equal((0, utils_1.toWei)(1));
  });
});
