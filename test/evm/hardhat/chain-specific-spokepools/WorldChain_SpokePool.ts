import { ethers, expect, Contract, FakeContract, SignerWithAddress, getContractFactory } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { smock } from "@defi-wonderland/smock";

describe("WorldChain Spoke Pool", function () {
  let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
  let owner: SignerWithAddress;
  let cctpTokenMessenger: FakeContract;
  let usdcBridgeAdapter: FakeContract;

  const USDC_BRIDGE = "0xbD80b06d3dbD0801132c6689429aC09Ca6D27f82";

  const tokenMessengerAbi = [
    {
      inputs: [],
      name: "localToken",
      outputs: [{ internalType: "address", name: "", type: "address" }],
      stateMutability: "view",
      type: "function",
    },
  ];

  const usdcBridgeAdapterAbi = [
    {
      inputs: [
        { internalType: "address", name: "_to", type: "address" },
        { internalType: "uint256", name: "_amount", type: "uint256" },
        { internalType: "uint32", name: "_minGasLimit", type: "uint32" },
      ],
      name: "sendMessage",
      outputs: [],
      stateMutability: "nonpayable",
      type: "function",
    },
  ];

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    cctpTokenMessenger = await smock.fake(tokenMessengerAbi);
    usdcBridgeAdapter = await smock.fake(usdcBridgeAdapterAbi, { address: USDC_BRIDGE });

    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("WorldChain_SpokePool", owner),
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

  describe("USDC Bridging", function () {
    const amountToReturn = ethers.utils.parseUnits("1000", 6); // 1000 USDC

    beforeEach(async function () {
      // Mint USDC to SpokePool
      await usdc.mint(spokePool.address, amountToReturn);
    });

    it("Should use USDC bridge when CCTP is not enabled", async function () {
      console.log(spokePool);
      // Mock that CCTP is not enabled
      await spokePool.setCCTPEnabled(false);

      // Call internal function through a test helper or event
      await spokePool.testBridgeTokensToHubPool(amountToReturn, usdc.address);

      // Verify USDC allowance was increased
      expect(await usdc.allowance(spokePool.address, USDC_BRIDGE)).to.equal(amountToReturn);

      // Verify bridge adapter was called with correct parameters
      expect(usdcBridgeAdapter.sendMessage).to.have.been.calledWith(
        hubPool.address,
        amountToReturn,
        await spokePool.l1Gas()
      );
    });

    it("Should use CCTP when enabled", async function () {
      // Mock that CCTP is enabled
      await spokePool.setCCTPEnabled(true);

      await spokePool.testBridgeTokensToHubPool(amountToReturn, usdc.address);

      // Verify CCTP messenger was used instead of USDC bridge
      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
      // Add assertions for CCTP messenger calls based on parent contract implementation
    });

    it("Should use standard bridge for non-USDC tokens", async function () {
      const wethAmount = ethers.utils.parseEther("1");
      await weth.deposit({ value: wethAmount });
      await weth.transfer(spokePool.address, wethAmount);

      await spokePool.testBridgeTokensToHubPool(wethAmount, weth.address);

      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
    });
  });

  describe("Error cases", function () {
    it("Should revert on reinitialization", async function () {
      await expect(spokePool.connect(owner).initialize(0, owner.address, hubPool.address)).to.be.reverted;
    });
  });
});
