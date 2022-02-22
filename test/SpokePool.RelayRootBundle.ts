import { expect, Contract, ethers, SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { mockRelayerRefundRoot, mockSlowRelayFulfillmentRoot } from "./constants";

let spokePool: Contract;
let dataWorker: SignerWithAddress;

describe("SpokePool Relay Bundle Logic", async function () {
  beforeEach(async function () {
    [dataWorker] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Relaying root stores root and emits event", async function () {
    await expect(spokePool.connect(dataWorker).relayRootBundle(mockRelayerRefundRoot, mockSlowRelayFulfillmentRoot))
      .to.emit(spokePool, "RelayedRootBundle")
      .withArgs(0, mockRelayerRefundRoot, mockSlowRelayFulfillmentRoot);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayFulfillmentRoot", mockSlowRelayFulfillmentRoot);
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", mockRelayerRefundRoot);
  });
});
