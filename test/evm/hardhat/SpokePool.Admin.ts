import { expect, ethers, Contract, SignerWithAddress, getContractFactory, addressToBytes } from "../../../utils/utils";
import { hre } from "../../../utils/utils.hre";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { destinationChainId, mockRelayerRefundRoot, mockSlowRelayRoot } from "./constants";

let spokePool: Contract, erc20: Contract;
let owner: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ spokePool, erc20 } = await spokePoolFixture());
  });
  it("Can set initial deposit ID", async function () {
    const spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("MockSpokePool", owner),
      [1, owner.address, owner.address],
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [owner.address] }
    );
    expect(await spokePool.numberOfDeposits()).to.equal(1);
  });

  it("Pause deposits", async function () {
    expect(await spokePool.pausedDeposits()).to.equal(false);
    await expect(spokePool.connect(owner).pauseDeposits(true)).to.emit(spokePool, "PausedDeposits").withArgs(true);
    expect(await spokePool.pausedDeposits()).to.equal(true);
    await expect(spokePool.connect(owner).pauseDeposits(false)).to.emit(spokePool, "PausedDeposits").withArgs(false);
    expect(await spokePool.pausedDeposits()).to.equal(false);
  });

  it("Pause fills", async function () {
    expect(await spokePool.pausedFills()).to.equal(false);
    await expect(spokePool.connect(owner).pauseFills(true)).to.emit(spokePool, "PausedFills").withArgs(true);
    expect(await spokePool.pausedFills()).to.equal(true);
    await expect(spokePool.connect(owner).pauseFills(false)).to.emit(spokePool, "PausedFills").withArgs(false);
    expect(await spokePool.pausedFills()).to.equal(false);
  });

  it("Delete rootBundle", async function () {
    await spokePool.connect(owner).relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayRoot", mockSlowRelayRoot);
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", mockRelayerRefundRoot);

    await expect(spokePool.connect(owner).emergencyDeleteRootBundle(0))
      .to.emit(spokePool, "EmergencyDeletedRootBundle")
      .withArgs(0);

    expect(await spokePool.rootBundles(0)).has.property("slowRelayRoot", ethers.utils.hexZeroPad("0x0", 32));
    expect(await spokePool.rootBundles(0)).has.property("relayerRefundRoot", ethers.utils.hexZeroPad("0x0", 32));
  });
});
