import { expect, ethers, Contract, SignerWithAddress, randomAddress } from "./utils";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { destinationChainId, mockRelayerRefundRoot, mockSlowRelayRoot } from "./constants";

let spokePool: Contract, erc20: Contract;
let owner: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ spokePool, erc20 } = await spokePoolFixture());
  });
  it("Enable token path", async function () {
    const destToken = randomAddress();
    await expect(spokePool.connect(owner).setEnableRoute(erc20.address, destToken, destinationChainId, true))
      .to.emit(spokePool, "EnabledDepositRoute")
      .withArgs(destinationChainId, erc20.address, destToken, true);
    const destTokenStruct = await spokePool.enabledDepositRoutes(erc20.address, destinationChainId);
    expect(destTokenStruct.enabled).to.equal(true);
    expect(destTokenStruct.destinationToken).to.equal(destToken);
  });
  it("Change deposit quote buffer", async function () {
    await expect(spokePool.connect(owner).setDepositQuoteTimeBuffer(60))
      .to.emit(spokePool, "SetDepositQuoteTimeBuffer")
      .withArgs(60);

    expect(await spokePool.depositQuoteTimeBuffer()).to.equal(60);
  });

  it("Delete rootBundle", async function () {
    await spokePool.connect(owner).relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayRoot", mockSlowRelayRoot);
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", mockRelayerRefundRoot);

    await expect(spokePool.connect(owner).emergencyDeleteRootBundle(0))
      .to.emit(spokePool, "EmergencyDeleteRootBundle")
      .withArgs(0);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayRoot", ethers.utils.hexZeroPad("0x0", 32));
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", ethers.utils.hexZeroPad("0x0", 32));
  });
});
