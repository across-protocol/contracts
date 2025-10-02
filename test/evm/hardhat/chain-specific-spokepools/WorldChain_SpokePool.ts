import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  createFakeFromABI,
  toWei,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface, IOpUSDCBridgeAdapterAbi } from "../../../../utils/abis";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { mockTreeRoot, amountToReturn } from "../constants";

describe("WorldChain Spoke Pool", function () {
  let hubPool: Contract, spokePool: Contract, weth: Contract, usdc: Contract;
  let owner: SignerWithAddress, relayer: SignerWithAddress;
  let cctpTokenMessenger: FakeContract;
  let cctpMinter: FakeContract;
  let l2StandardBridge: FakeContract;

  let usdcBridgeAdapter: FakeContract;
  let crossDomainMessenger: FakeContract;
  let messengerSigner: SignerWithAddress;
  const USDC_BRIDGE = "0xbD80b06d3dbD0801132c6689429aC09Ca6D27f82";
  const CROSS_DOMAIN_MESSENGER = "0x4200000000000000000000000000000000000007";
  const L2_STANDARD_BRIDGE = "0x4200000000000000000000000000000000000010";

  beforeEach(async function () {
    [owner, relayer] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    // Fake Contract for cross domain messenger at CROSS_DOMAIN_MESSENGER
    crossDomainMessenger = await createFakeFromABI(
      ["function xDomainMessageSender() external view returns (address)"],
      CROSS_DOMAIN_MESSENGER
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address); // Set the owner as the xDomainMessageSender

    cctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    usdcBridgeAdapter = await createFakeFromABI(IOpUSDCBridgeAdapterAbi, USDC_BRIDGE);
    cctpMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpTokenMessenger.localMinter.returns(cctpMinter.address);
    cctpMinter.burnLimitsPerMessage.returns(usdc.address);
    cctpTokenMessenger.depositForBurn.returns(1);

    l2StandardBridge = await createFakeFromABI(
      ["function withdrawTo(address,address,uint256,uint256,bytes) external payable"],
      L2_STANDARD_BRIDGE
    );

    // Deploy spoke pool
    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("WorldChain_SpokePool", owner),
      [0, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, usdc.address, cctpTokenMessenger.address],
      }
    );

    // Set up and fund the cross domain messenger account
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [CROSS_DOMAIN_MESSENGER],
    });
    messengerSigner = await ethers.getSigner(CROSS_DOMAIN_MESSENGER); // Signer for the cross domain messenger
    await owner.sendTransaction({
      to: CROSS_DOMAIN_MESSENGER,
      value: toWei("1"),
    });
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

  describe("Token Bridging", function () {
    it("Should use USDC bridge when CCTP is not enabled", async function () {
      // Deploy with CCTP disabled.
      spokePool = await hre.upgrades.deployProxy(
        await getContractFactory("WorldChain_SpokePool", owner),
        [0, owner.address, hubPool.address],
        {
          kind: "uups",
          unsafeAllow: ["delegatecall"],
          constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, usdc.address, ethers.constants.AddressZero],
        }
      );

      await usdc.mint(spokePool.address, amountToReturn);

      const { leaves, tree } = await constructSingleRelayerRefundTree(usdc.address, await spokePool.chainId());

      // Call as cross domain messenger
      await spokePool.connect(messengerSigner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

      await spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

      expect(await usdc.allowance(spokePool.address, USDC_BRIDGE)).to.equal(amountToReturn);
      expect(usdcBridgeAdapter.sendMessage).to.have.been.calledWith(
        hubPool.address,
        amountToReturn,
        await spokePool.l1Gas()
      );
    });

    it("Should use CCTP when enabled", async function () {
      await usdc.mint(spokePool.address, amountToReturn);

      const { leaves, tree } = await constructSingleRelayerRefundTree(usdc.address, await spokePool.chainId());

      // Call as cross domain messenger
      await spokePool.connect(messengerSigner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

      await spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

      expect(await usdc.allowance(spokePool.address, cctpTokenMessenger.address)).to.equal(amountToReturn);

      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
    });

    it("Should use standard bridge for non-USDC tokens", async function () {
      await weth.deposit({ value: amountToReturn });
      await weth.transfer(spokePool.address, amountToReturn);

      const { leaves, tree } = await constructSingleRelayerRefundTree(weth.address, await spokePool.chainId());

      // Call as cross domain messenger
      await spokePool.connect(messengerSigner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

      await spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

      expect(usdcBridgeAdapter.sendMessage).to.not.have.been.called;
      expect(await weth.allowance(spokePool.address, USDC_BRIDGE)).to.equal(0);
    });
  });

  describe("Error cases", function () {
    it("Should revert on reinitialization", async function () {
      await expect(spokePool.connect(owner).initialize(0, owner.address, hubPool.address)).to.be.reverted;
    });
  });
});
