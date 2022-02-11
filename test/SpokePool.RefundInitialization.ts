import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { mockDestinationDistributionRoot, mockSlowRelayFulfillmentRoot } from "./constants";

let spokePool: Contract;
let dataWorker: SignerWithAddress;

describe("SpokePool Initialize Relayer Refund Logic", async function () {
  beforeEach(async function () {
    [dataWorker] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Initializing root stores root and emits event", async function () {
    await expect(
      spokePool
        .connect(dataWorker)
        .initializeRelayerRefund(mockDestinationDistributionRoot, mockSlowRelayFulfillmentRoot)
    )
      .to.emit(spokePool, "InitializedRelayerRefund")
      .withArgs(0, mockDestinationDistributionRoot, mockSlowRelayFulfillmentRoot);

    expect(await spokePool.relayerRefunds(0)).has.property("slowRelayFulfillmentRoot", mockSlowRelayFulfillmentRoot);
    expect(await spokePool.relayerRefunds(0)).has.property("distributionRoot", mockDestinationDistributionRoot);
  });
});
