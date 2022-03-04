"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const constants_1 = require("./constants");
let spokePool;
let dataWorker;
describe("SpokePool Relay Bundle Logic", async function () {
  beforeEach(async function () {
    [dataWorker] = await utils_1.ethers.getSigners();
    ({ spokePool } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
  });
  it("Relaying root stores root and emits event", async function () {
    await (0, utils_1.expect)(
      spokePool.connect(dataWorker).relayRootBundle(constants_1.mockRelayerRefundRoot, constants_1.mockSlowRelayRoot)
    )
      .to.emit(spokePool, "RelayedRootBundle")
      .withArgs(0, constants_1.mockRelayerRefundRoot, constants_1.mockSlowRelayRoot);
    (0, utils_1.expect)(await spokePool.rootBundles(0)).has.property("slowRelayRoot", constants_1.mockSlowRelayRoot);
    (0, utils_1.expect)(await spokePool.rootBundles(0)).has.property(
      "relayerRefundRoot",
      constants_1.mockRelayerRefundRoot
    );
  });
});
