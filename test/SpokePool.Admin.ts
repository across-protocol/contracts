import { expect, ethers, Contract, SignerWithAddress, getContractFactory } from "./utils";
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
  it("Set bridge adapter", async function () {
    const newAdapter = await (await getContractFactory("Mock_Adapter", owner)).deploy();

    await expect(spokePool.connect(owner).setBridgeAdapter(newAdapter.address))
      .to.emit(spokePool, "BridgeAdapterSet")
      .withArgs(newAdapter.address);

    expect(await spokePool.bridgeAdapter()).to.equal(newAdapter.address);
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
