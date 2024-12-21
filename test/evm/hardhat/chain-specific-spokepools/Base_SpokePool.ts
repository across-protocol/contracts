/* eslint-disable node/no-missing-import */
import { ethers, expect, Contract, FakeContract, SignerWithAddress, getContractFactory } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { smock } from "@defi-wonderland/smock";

let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress;
let cctpTokenMessenger: FakeContract;

// ABI for CCTP Token Messenger
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
    cctpTokenMessenger.localToken.returns(usdc.address);

    // Deploy Base SpokePool
    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Base_SpokePool", owner),
      [0, hubPool.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, usdc.address, cctpTokenMessenger.address],
      }
    );
  });

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      expect(await spokePool._l2Usdc).to.equal(usdc.address);
      expect(await spokePool.cctpTokenMessenger()).to.equal(cctpTokenMessenger.address);
    });

    it("Should start with deposit ID 0", async function () {
      expect(await spokePool.numberOfDeposits()).to.equal(0);
    });
  });

  describe("Error cases", function () {
    it("Should revert if trying to initialize twice", async function () {
      await expect(spokePool.initialize(0, hubPool.address, hubPool.address)).to.be.revertedWith(
        "Initializable: contract is already initialized"
      );
    });
  });
});
