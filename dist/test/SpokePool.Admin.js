"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const constants_1 = require("./constants");
let spokePool, erc20;
let owner;
describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await utils_1.ethers.getSigners();
    ({ spokePool, erc20 } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
  });
  it("Enable token path", async function () {
    await (0, utils_1.expect)(
      spokePool.connect(owner).setEnableRoute(erc20.address, constants_1.destinationChainId, true)
    )
      .to.emit(spokePool, "EnabledDepositRoute")
      .withArgs(erc20.address, constants_1.destinationChainId, true);
    (0, utils_1.expect)(await spokePool.enabledDepositRoutes(erc20.address, constants_1.destinationChainId)).to.equal(
      true
    );
  });
  it("Change deposit quote buffer", async function () {
    await (0, utils_1.expect)(spokePool.connect(owner).setDepositQuoteTimeBuffer(60))
      .to.emit(spokePool, "SetDepositQuoteTimeBuffer")
      .withArgs(60);
    (0, utils_1.expect)(await spokePool.depositQuoteTimeBuffer()).to.equal(60);
  });
});
