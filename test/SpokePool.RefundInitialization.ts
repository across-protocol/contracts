import { expect, Contract, ethers, SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { mockDestinationDistributionRoot, mockSlowRelayRoot } from "./constants";

let spokePool: Contract;
let dataWorker: SignerWithAddress;

describe("SpokePool Initialize Relayer Refund Logic", async function () {
  beforeEach(async function () {
    [dataWorker] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Initializing root stores root and emits event", async function () {
    await expect(
      spokePool.connect(dataWorker).initializeRelayerRefund(mockDestinationDistributionRoot, mockSlowRelayRoot)
    )
      .to.emit(spokePool, "InitializedRelayerRefund")
      .withArgs(0, mockDestinationDistributionRoot, mockSlowRelayRoot);

    expect(await spokePool.relayerRefunds(0)).has.property("slowRelayRoot", mockSlowRelayRoot);
    expect(await spokePool.relayerRefunds(0)).has.property("distributionRoot", mockDestinationDistributionRoot);
  });
});
