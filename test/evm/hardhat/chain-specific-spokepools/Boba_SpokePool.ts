import { ethers, expect, Contract, SignerWithAddress, getContractFactory } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";

describe("Boba Spoke Pool", function () {
  let hubPool: Contract, spokePool: Contract, weth: Contract;
  let owner: SignerWithAddress;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, hubPool } = await hubPoolFixture());

    // Deploy spoke pool
    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Boba_SpokePool", owner),
      [0, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60],
      }
    );
  });

  describe("Initialization", function () {
    it("Should initialize with correct constructor parameters", async function () {
      expect(await spokePool.wrappedNativeToken()).to.equal(weth.address);
    });

    it("Should initialize with correct proxy parameters", async function () {
      expect(await spokePool.numberOfDeposits()).to.equal(0);
      expect(await spokePool.crossDomainAdmin()).to.equal(owner.address);
      expect(await spokePool.withdrawalRecipient()).to.equal(hubPool.address);
    });

    it("Should initialize with correct L2_ETH", async function () {
      expect(await spokePool.l2Eth()).to.equal("0x4200000000000000000000000000000000000006");
    });

    it("Should revert on reinitialization", async function () {
      await expect(spokePool.connect(owner).initialize(0, owner.address, hubPool.address)).to.be.reverted;
    });
  });
});
