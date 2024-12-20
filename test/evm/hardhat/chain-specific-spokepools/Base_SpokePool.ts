/* eslint-disable node/no-missing-import */
import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedContract,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";

let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let cctpTokenMessenger: FakeContract;

// ABI for CCTP Token Messenger
const tokenMessengerAbi = [
  {
    inputs: [
      { internalType: "address", name: "recipient", type: "address" },
      { internalType: "uint256", name: "amount", type: "uint256" },
      { internalType: "uint32", name: "destinationDomain", type: "uint32" },
    ],
    name: "depositForBurn",
    outputs: [{ internalType: "uint64", name: "", type: "uint64" }],
    stateMutability: "nonpayable",
    type: "function",
  },
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
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    // Create fake CCTP Token Messenger instead of mock
    cctpTokenMessenger = await smock.fake(tokenMessengerAbi, {
      address: "0x0a992d191DEeC32aFe36203Ad87D7d289a738F81", // Example address
    });
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

    // Seed spoke pool with tokens for testing
    await seedContract(spokePool, relayer, [usdc], weth, amountHeldByPool);
  });

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      expect(await spokePool.crossDomainAdmin()).to.equal(hubPool.address);
      expect(await spokePool.withdrawalRecipient()).to.equal(hubPool.address);
      expect(await spokePool.wrappedNativeToken()).to.equal(weth.address);
      expect(await spokePool.l2Usdc()).to.equal(usdc.address);
      expect(await spokePool.cctpTokenMessenger()).to.equal(cctpTokenMessenger.address);
    });

    it("Should start with deposit ID 0", async function () {
      expect(await spokePool.numberOfDeposits()).to.equal(0);
    });
  });

  describe("Token transfers", function () {
    it("Should correctly bridge tokens to hub pool", async function () {
      const { leaves, tree } = await constructSingleRelayerRefundTree(
        usdc.address,
        await spokePool.callStatic.chainId()
      );
      await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

      await spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

      // Verify CCTP messenger was called correctly
      expect(cctpTokenMessenger.depositForBurn).to.have.been.calledWith(
        hubPool.address,
        amountToReturn,
        1 // Ethereum domain ID
      );
    });

    it("Should handle wrapped native token transfers", async function () {
      const { leaves, tree } = await constructSingleRelayerRefundTree(
        weth.address,
        await spokePool.callStatic.chainId()
      );
      await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

      await expect(() =>
        spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.changeTokenBalances(weth, [spokePool, hubPool], [amountToReturn.mul(-1), amountToReturn]);
    });
  });

  describe("Admin functions", function () {
    it("Only cross domain owner can upgrade logic contract", async function () {
      const implementation = await hre.upgrades.deployImplementation(
        await getContractFactory("Base_SpokePool", owner),
        {
          kind: "uups",
          unsafeAllow: ["delegatecall"],
          constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, usdc.address, cctpTokenMessenger.address],
        }
      );

      await expect(spokePool.connect(rando).upgradeTo(implementation)).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      await spokePool.connect(owner).upgradeTo(implementation);
    });

    it("Only owner can set the cross domain admin", async function () {
      await expect(spokePool.connect(rando).setCrossDomainAdmin(rando.address)).to.be.reverted;
      await spokePool.connect(owner).setCrossDomainAdmin(rando.address);
      expect(await spokePool.crossDomainAdmin()).to.equal(rando.address);
    });

    it("Only owner can enable a route", async function () {
      await expect(spokePool.connect(rando).setEnableRoute(usdc.address, 1, true)).to.be.reverted;
      await spokePool.connect(owner).setEnableRoute(usdc.address, 1, true);
      expect(await spokePool.enabledDepositRoutes(usdc.address, 1)).to.equal(true);
    });
  });

  describe("CCTP functionality", function () {
    it("Should correctly handle CCTP token deposits", async function () {
      const amount = ethers.utils.parseUnits("100", 6); // USDC has 6 decimals
      const destinationDomain = 1; // Ethereum domain

      // Mock the CCTP messenger response
      cctpTokenMessenger.depositForBurn.returns(123); // Return some nonce

      // Perform deposit
      await usdc.connect(owner).approve(spokePool.address, amount);
      const depositTx = await spokePool
        .connect(owner)
        .deposit(usdc.address, amount, destinationDomain, owner.address, 0);

      // Verify CCTP messenger was called with correct parameters
      expect(cctpTokenMessenger.depositForBurn).to.have.been.calledWith(hubPool.address, amount, destinationDomain);

      await expect(depositTx)
        .to.emit(spokePool, "TokensDeposited")
        .withArgs(owner.address, usdc.address, amount, destinationDomain);
    });
  });

  describe("Error cases", function () {
    it("Should revert if trying to initialize twice", async function () {
      await expect(spokePool.initialize(0, hubPool.address, hubPool.address)).to.be.revertedWith(
        "Initializable: contract is already initialized"
      );
    });

    it("Should revert if CCTP messenger call fails", async function () {
      const amount = ethers.utils.parseUnits("100", 6);

      // Make the CCTP messenger revert
      cctpTokenMessenger.depositForBurn.reverts("CCTP: Transfer failed");

      await usdc.connect(owner).approve(spokePool.address, amount);
      await expect(spokePool.connect(owner).deposit(usdc.address, amount, 1, owner.address, 0)).to.be.revertedWith(
        "CCTP: Transfer failed"
      );
    });
  });
});
