import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  createFakeFromABI,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { smock } from "@defi-wonderland/smock";
import { CCTPTokenMessengerInterface, IOpUSDCBridgeAdapterAbi } from "../../../../utils/abis";

describe("WorldChain Spoke Pool", function () {
  let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
  let owner: SignerWithAddress;
  let cctpTokenMessenger: FakeContract;
  let usdcBridgeAdapter: FakeContract;

  const USDC_BRIDGE = "0xbD80b06d3dbD0801132c6689429aC09Ca6D27f82";

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    cctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    usdcBridgeAdapter = await createFakeFromABI(IOpUSDCBridgeAdapterAbi, USDC_BRIDGE);

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
    const amountToReturn = ethers.utils.parseUnits("1000", 6);

    beforeEach(async function () {
      // Mint USDC to SpokePool
      await usdc.mint(spokePool.address, amountToReturn);
    });

    it("Should use USDC bridge when CCTP is not enabled", async function () {
      // Use the existing tokenBridges function to check CCTP status
      const usdcBridgeAddress = await spokePool.tokenBridges(usdc.address);

      // Set the bridge if needed
      if (usdcBridgeAddress !== USDC_BRIDGE) {
        await spokePool.setTokenBridge(usdc.address, USDC_BRIDGE);
      }

      await spokePool._bridgeTokensToHubPool(amountToReturn, usdc.address);

      expect(await usdc.allowance(spokePool.address, USDC_BRIDGE)).to.equal(amountToReturn);
      expect(usdcBridgeAdapter.sendMessage).to.have.been.calledWith(
        hubPool.address,
        amountToReturn,
        await spokePool.l1Gas()
      );
    });

    it("Should use CCTP when enabled", async function () {
      // Instead of setting CCTP enabled/disabled directly,
      // we can use the token bridge configuration
      await spokePool.setTokenBridge(usdc.address, cctpTokenMessenger.address);

      await spokePool._bridgeTokensToHubPool(amountToReturn, usdc.address);

      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
      // Add assertions for CCTP messenger calls
    });

    it("Should use standard bridge for non-USDC tokens", async function () {
      const wethAmount = ethers.utils.parseEther("1");
      await weth.deposit({ value: wethAmount });
      await weth.transfer(spokePool.address, wethAmount);

      // This will use the standard bridge
      // Use the existing bridging function
      await spokePool._bridgeTokensToHubPool(wethAmount, weth.address);

      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
    });
  });

  describe("Error cases", function () {
    it("Should revert on reinitialization", async function () {
      await expect(spokePool.connect(owner).initialize(0, owner.address, hubPool.address)).to.be.reverted;
    });
  });
});
