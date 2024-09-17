import { expect, Contract, ethers, SignerWithAddress } from "../../../utils/utils";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { mockRelayerRefundRoot, mockSlowRelayRoot } from "./constants";

let spokePool: Contract;
let dataWorker: SignerWithAddress;

describe("SpokePool Relay Bundle Logic", async function () {
  beforeEach(async function () {
    [dataWorker] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Relaying root stores root and emits event", async function () {
    await expect(spokePool.connect(dataWorker).relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot))
      .to.emit(spokePool, "RelayedRootBundle")
      .withArgs(0, mockRelayerRefundRoot, mockSlowRelayRoot);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayRoot", mockSlowRelayRoot);
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", mockRelayerRefundRoot);
  });
});
