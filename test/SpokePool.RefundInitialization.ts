import { expect, Contract, ethers, SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { mockDestinationDistributionRoot } from "./constants";

let spokePool: Contract;
let caller: SignerWithAddress;

describe("SpokePool Initialize Relayer Refund Logic", async function () {
  beforeEach(async function () {
    [caller] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Initializing root stores root and emits event", async function () {
    await expect(spokePool.connect(caller).initializeRelayerRefund(mockDestinationDistributionRoot))
      .to.emit(spokePool, "InitializedRelayerRefund")
      .withArgs(0, mockDestinationDistributionRoot);
    expect(await spokePool.relayerRefunds(0)).to.equal(mockDestinationDistributionRoot);
  });
});
