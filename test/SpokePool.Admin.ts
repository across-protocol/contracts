import { expect, ethers, Contract, SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { destinationChainId, mockRelayerRefundRoot, mockSlowRelayRoot, rootBundleId } from "./constants";

let spokePool: Contract, erc20: Contract;
let owner: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ spokePool, erc20 } = await spokePoolFixture());
  });
  it("Enable token path", async function () {
    await expect(spokePool.connect(owner).setEnableRoute(erc20.address, destinationChainId, true))
      .to.emit(spokePool, "EnabledDepositRoute")
      .withArgs(erc20.address, destinationChainId, true);
    expect(await spokePool.enabledDepositRoutes(erc20.address, destinationChainId)).to.equal(true);
  });
  it("Change deposit quote buffer", async function () {
    await expect(spokePool.connect(owner).setDepositQuoteTimeBuffer(60))
      .to.emit(spokePool, "SetDepositQuoteTimeBuffer")
      .withArgs(60);

    expect(await spokePool.depositQuoteTimeBuffer()).to.equal(60);
  });

  it("Delete rootBundle", async function () {
    await expect(spokePool.connect(owner).relayRootBundle(rootBundleId, mockRelayerRefundRoot, mockSlowRelayRoot))
      .to.emit(spokePool, "RelayedRootBundle")
      .withArgs(rootBundleId, mockRelayerRefundRoot, mockSlowRelayRoot);

    expect(await spokePool.rootBundles(rootBundleId)).has.property("slowRelayRoot", mockSlowRelayRoot);
    expect(await spokePool.rootBundles(rootBundleId)).has.property("relayerRefundRoot", mockRelayerRefundRoot);

    await expect(spokePool.connect(owner).emergencyDeleteRootBundle(rootBundleId))
      .to.emit(spokePool, "EmergencyDeleteRootBundle")
      .withArgs(rootBundleId);

    expect(await spokePool.rootBundles(rootBundleId)).has.property("slowRelayRoot", ethers.utils.hexZeroPad("0x0", 32));
    expect(await spokePool.rootBundles(rootBundleId)).has.property(
      "relayerRefundRoot",
      ethers.utils.hexZeroPad("0x0", 32)
    );
  });
});
