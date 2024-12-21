/* eslint-disable node/no-missing-import */
import { ethers, expect, Contract, FakeContract, SignerWithAddress, getContractFactory } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { smock } from "@defi-wonderland/smock";

let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress;
let cctpTokenMessenger: FakeContract;

const tokenMessengerAbi = [
  {
    inputs: [],
    name: "localToken",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
];

describe("Base Spoke Pool", function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    cctpTokenMessenger = await smock.fake(tokenMessengerAbi);

    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Base_SpokePool", owner),
      [0, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, usdc.address, cctpTokenMessenger.address],
      }
    );
  });

  describe("Initialization", function () {
    it("Should initialize with correct constructor parameters", async function () {
      expect(await spokePool.wrappedNativeToken()).to.equal(weth.address);
      expect(await spokePool.usdcToken()).to.equal(usdc.address);
      expect(await spokePool.cctpTokenMessenger()).to.equal(cctpTokenMessenger.address);
    });

    it("Should initialize with correct proxy parameters", async function () {
      expect(await spokePool.numberOfDeposits()).to.equal(0);
      expect(await spokePool.crossDomainAdmin()).to.equal(owner.address);
      expect(await spokePool.withdrawalRecipient()).to.equal(hubPool.address);
    });

    it("Should initialize with correct OVM_ETH", async function () {
      expect(await spokePool.l2Eth()).to.equal("0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000");
    });
  });

  describe("Error cases", function () {
    it("Should revert on reinitialization", async function () {
      await expect(spokePool.connect(owner).initialize(0, owner.address, hubPool.address)).to.be.reverted;
    });
  });
});
