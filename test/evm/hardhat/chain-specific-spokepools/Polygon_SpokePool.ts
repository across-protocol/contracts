import {
  mockTreeRoot,
  amountToReturn,
  amountHeldByPool,
  zeroAddress,
  TokenRolesEnum,
  originChainId,
  repaymentChainId,
} from "../constants";
import {
  ethers,
  expect,
  Contract,
  SignerWithAddress,
  getContractFactory,
  createFake,
  seedContract,
  toWei,
  randomBigNumber,
  seedWallet,
  FakeContract,
  createFakeFromABI,
  addressToBytes,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { buildRelayerRefundLeaves, buildRelayerRefundTree, constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { randomBytes } from "crypto";
import { V3RelayData, deployMockSpokePoolCaller } from "../fixtures/SpokePool.Fixture";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";

let hubPool: Contract, polygonSpokePool: Contract, dai: Contract, weth: Contract, l2Dai: string, l2Usdc: string;
let polygonRegistry: FakeContract,
  erc20Predicate: FakeContract,
  l2CctpTokenMessenger: FakeContract,
  cctpTokenMinter: FakeContract;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, fxChild: SignerWithAddress;

describe("Polygon Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, fxChild, rando] = await ethers.getSigners();
    ({ weth, hubPool, l2Dai, l2Usdc } = await hubPoolFixture());

    // The spoke pool exists on l2, so add a random chainId for L1 to ensure that the L2's block.chainid will not match.
    const l1ChainId = randomBigNumber();
    const l2ChainId = await owner.getChainId();

    polygonRegistry = await createFake("PolygonRegistryMock");
    erc20Predicate = await createFake("PolygonERC20PredicateMock");
    l2CctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    l2CctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));

    polygonRegistry.erc20Predicate.returns(() => erc20Predicate.address);

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, polygonRegistry.address, weth.address, weth.address, l1ChainId, l2ChainId);

    dai = await (await getContractFactory("PolygonERC20Test", owner)).deploy();
    await dai.addMember(TokenRolesEnum.MINTER, owner.address);

    polygonSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Polygon_SpokePool", owner),
      [0, polygonTokenBridger.address, owner.address, hubPool.address, fxChild.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address],
      }
    );

    await seedContract(polygonSpokePool, relayer, [dai], weth, amountHeldByPool);
    await seedWallet(owner, [], weth, toWei("1"));
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("Polygon_SpokePool", owner),
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address],
      }
    );

    // upgradeTo fails unless called by cross domain admin
    const upgradeData = polygonSpokePool.interface.encodeFunctionData("upgradeTo", [implementation]);

    // Wrong rootMessageSender address.
    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, upgradeData)
    ).to.be.revertedWith("NotHubPool");

    // Wrong calling address.
    await expect(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, upgradeData)
    ).to.be.revertedWith("NotFxChild");

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, upgradeData);
  });

  it("Only correct caller can set the cross domain admin", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;

    const setCrossDomainAdminData = polygonSpokePool.interface.encodeFunctionData("setCrossDomainAdmin", [
      rando.address,
    ]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setCrossDomainAdminData)).to
      .be.reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setCrossDomainAdminData)).to
      .be.reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setCrossDomainAdminData);
    expect(await polygonSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Only correct caller can set the hub pool address", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setWithdrawalRecipient(rando.address)).to.be.reverted;

    const setHubPoolData = polygonSpokePool.interface.encodeFunctionData("setWithdrawalRecipient", [rando.address]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setHubPoolData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setHubPoolData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setHubPoolData);
    expect(await polygonSpokePool.withdrawalRecipient()).to.equal(rando.address);
  });

  it("Only correct caller can enable a route", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.setEnableRoute(l2Dai, 1, true)).to.be.reverted;

    const setEnableRouteData = polygonSpokePool.interface.encodeFunctionData("setEnableRoute", [l2Dai, 1, true]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, setEnableRouteData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, setEnableRouteData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, setEnableRouteData);
    expect(await polygonSpokePool.enabledDepositRoutes(l2Dai, 1)).to.equal(true);
  });

  it("Only correct caller can initialize a relayer refund", async function () {
    // Cannot call directly
    await expect(polygonSpokePool.relayRootBundle(mockTreeRoot, mockTreeRoot)).to.be.reverted;

    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      mockTreeRoot,
      mockTreeRoot,
    ]);

    // Wrong rootMessageSender address.
    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, relayRootBundleData)).to.be
      .reverted;

    // Wrong calling address.
    await expect(polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, relayRootBundleData)).to.be
      .reverted;

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    expect((await polygonSpokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await polygonSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Cannot re-enter processMessageFromRoot", async function () {
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      mockTreeRoot,
      mockTreeRoot,
    ]);
    const processMessageFromRootData = polygonSpokePool.interface.encodeFunctionData("processMessageFromRoot", [
      0,
      owner.address,
      relayRootBundleData,
    ]);

    await expect(polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, processMessageFromRootData))
      .to.be.reverted;
  });

  it("Only owner can delete a relayer refund", async function () {
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      mockTreeRoot,
      mockTreeRoot,
    ]);

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    // Cannot call directly
    await expect(polygonSpokePool.emergencyDeleteRootBundle(0)).to.be.reverted;

    const emergencyDeleteRelayRootBundleData = polygonSpokePool.interface.encodeFunctionData(
      "emergencyDeleteRootBundle",
      [0]
    );

    // Wrong rootMessageSender address.
    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, rando.address, emergencyDeleteRelayRootBundleData)
    ).to.be.reverted;

    // Wrong calling address.
    await expect(
      polygonSpokePool.connect(rando).processMessageFromRoot(0, owner.address, emergencyDeleteRelayRootBundleData)
    ).to.be.reverted;

    await expect(
      polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, emergencyDeleteRelayRootBundleData)
    ).to.not.be.reverted;
    expect((await polygonSpokePool.rootBundles(0)).slowRelayRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
    expect((await polygonSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
  });

  it("Can wrap native token", async function () {
    await expect(() =>
      rando.sendTransaction({ to: polygonSpokePool.address, value: toWei("0.1") })
    ).to.changeEtherBalance(polygonSpokePool, toWei("0.1"));
    await expect(() => polygonSpokePool.wrap()).to.changeTokenBalance(weth, polygonSpokePool, toWei("0.1"));
  });

  it("Bridge tokens to hub pool correctly sends tokens through the PolygonTokenBridger", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await polygonSpokePool.callStatic.chainId()
    );
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);

    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);
    const bridger = await polygonSpokePool.polygonTokenBridger();

    // Checks that there's a burn event from the bridger.
    await expect(polygonSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0])))
      .to.emit(dai, "Transfer")
      .withArgs(bridger, zeroAddress, amountToReturn);
  });

  it("Must be EOA to execute relayer refund leaf with amountToReturn > 0", async function () {
    const l2ChainId = await owner.getChainId();
    const leaves = buildRelayerRefundLeaves(
      [l2ChainId, l2ChainId], // Destination chain ID.
      [amountToReturn, ethers.constants.Zero], // amountToReturn.
      [dai.address, dai.address], // l2Token.
      [[], []], // refundAddresses.
      [[], []] // refundAmounts.
    );
    const tree = await buildRelayerRefundTree(leaves);

    // Relay leaves to Spoke
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    // Deploying mock caller tries to execute leaf from within constructor:
    await expect(
      deployMockSpokePoolCaller(polygonSpokePool, 0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.be.revertedWith("NotEOA");

    // Executing leaf with amountToReturn == 0 is fine through contract caller.
    await expect(deployMockSpokePoolCaller(polygonSpokePool, 0, leaves[1], tree.getHexProof(leaves[1]))).to.not.be
      .reverted;
  });

  it("Cannot combine fill and execute leaf functions in same tx", async function () {
    const l2ChainId = await owner.getChainId();
    const leaves = buildRelayerRefundLeaves(
      [l2ChainId, l2ChainId], // Destination chain ID.
      [ethers.constants.Zero, ethers.constants.Zero], // amountToReturn.
      [dai.address, dai.address], // l2Token.
      [[], []], // refundAddresses.
      [[], []] // refundAmounts.
    );
    const tree = await buildRelayerRefundTree(leaves);

    // Relay leaves to Spoke
    const relayRootBundleData = polygonSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);
    await polygonSpokePool.connect(fxChild).processMessageFromRoot(0, owner.address, relayRootBundleData);

    // Deploy message handler and create fill with message that should succeed in isolation:
    const acrossMessageHandler = await createFake("AcrossMessageHandlerMock");
    await seedWallet(relayer, [dai], weth, toWei("2"));
    await dai.connect(relayer).approve(polygonSpokePool.address, toWei("2"));

    const executeLeafData = [
      polygonSpokePool.interface.encodeFunctionData("executeRelayerRefundLeaf", [
        0,
        leaves[0],
        tree.getHexProof(leaves[0]),
      ]),
      polygonSpokePool.interface.encodeFunctionData("executeRelayerRefundLeaf", [
        0,
        leaves[1],
        tree.getHexProof(leaves[1]),
      ]),
    ];
    const currentTime = (await polygonSpokePool.getCurrentTime()).toNumber();
    const relayData: V3RelayData = {
      depositor: addressToBytes(owner.address),
      recipient: addressToBytes(acrossMessageHandler.address),
      exclusiveRelayer: addressToBytes(zeroAddress),
      inputToken: addressToBytes(dai.address),
      outputToken: addressToBytes(dai.address),
      inputAmount: toWei("1"),
      outputAmount: toWei("1"),
      originChainId: originChainId,
      depositId: 0,
      fillDeadline: currentTime + 7200,
      exclusivityDeadline: 0,
      message: "0x1234",
    };
    const fillData = [
      polygonSpokePool.interface.encodeFunctionData("fillV3Relay", [
        relayData,
        repaymentChainId,
        addressToBytes(relayer.address),
      ]),
      polygonSpokePool.interface.encodeFunctionData("fillV3Relay", [
        { ...relayData, depositId: 1 },
        repaymentChainId,
        addressToBytes(relayer.address),
      ]),
    ];
    const otherData = [polygonSpokePool.interface.encodeFunctionData("wrap", [])];

    // Fills and execute leaf should succeed in isolation:
    // 1. Two fills
    // 2. One fill
    // 3. Two execution leaves
    // 4. One execution leaf
    await expect(polygonSpokePool.connect(relayer).estimateGas.multicall(fillData)).to.not.be.reverted;
    await expect(polygonSpokePool.connect(relayer).estimateGas.multicall([fillData[0]])).to.not.be.reverted;
    await expect(polygonSpokePool.connect(relayer).estimateGas.multicall(executeLeafData)).to.not.be.reverted;
    await expect(polygonSpokePool.connect(relayer).estimateGas.multicall([executeLeafData[0]])).to.not.be.reverted;

    // Can combine fill and other public function
    await expect(polygonSpokePool.connect(relayer).estimateGas.multicall([...fillData, ...otherData])).to.not.be
      .reverted;

    // When combining fills and executions in any order, reverts.
    // @dev: multicall() seems to suppress specific revert message so we can't use revertedWith()
    await expect(polygonSpokePool.connect(relayer).multicall([...fillData, ...executeLeafData])).to.be.reverted;
    await expect(polygonSpokePool.connect(relayer).multicall([...fillData, ...otherData, ...executeLeafData])).to.be
      .reverted;
    await expect(polygonSpokePool.connect(relayer).multicall([...otherData, ...executeLeafData])).to.be.reverted;
    await expect(polygonSpokePool.connect(relayer).multicall([...executeLeafData, ...fillData])).to.be.reverted;
    await expect(
      polygonSpokePool.connect(relayer).multicall([fillData[0], executeLeafData[0], fillData[1], executeLeafData[1]])
    ).to.be.reverted;
    await expect(
      polygonSpokePool.connect(relayer).multicall([executeLeafData[0], fillData[0], executeLeafData[1], fillData[1]])
    ).to.be.reverted;
  });
  it("PolygonTokenBridger retrieves and unwraps tokens correctly", async function () {
    const l1ChainId = await owner.getChainId();

    // Retrieve can only be performed on L1, so seed the L2 chainId with a non matching value.
    const l2ChainId = randomBigNumber();
    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, polygonRegistry.address, weth.address, weth.address, l1ChainId, l2ChainId);

    await expect(() =>
      owner.sendTransaction({ to: polygonTokenBridger.address, value: toWei("1") })
    ).to.changeEtherBalance(polygonTokenBridger, toWei("1"));

    // Retrieve automatically unwraps
    await expect(() => polygonTokenBridger.connect(owner).retrieve(weth.address)).to.changeTokenBalance(
      weth,
      hubPool,
      toWei("1")
    );
  });

  it("PolygonTokenBridger doesn't allow L1 actions on L2", async function () {
    // Make sure the L1 chain is different from the chainId where this is deployed.
    const l1ChainId = randomBigNumber();
    const l2ChainId = await owner.getChainId();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, polygonRegistry.address, weth.address, weth.address, l1ChainId, l2ChainId);

    // Cannot call retrieve on the contract on L2.
    await weth.connect(owner).transfer(polygonTokenBridger.address, toWei("1"));
    await expect(polygonTokenBridger.connect(owner).retrieve(weth.address)).to.be.revertedWith(
      "Cannot run method on this chain"
    );

    await expect(polygonTokenBridger.connect(owner).callExit("0x")).to.be.revertedWith(
      "Cannot run method on this chain"
    );
  });

  it("PolygonTokenBridger doesn't allow L2 actions on L1", async function () {
    const l1ChainId = await owner.getChainId();

    // Make sure the L1 chain is different from the chainId where this is deployed.
    const l2ChainId = randomBigNumber();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, polygonRegistry.address, weth.address, weth.address, l1ChainId, l2ChainId);

    await weth.connect(owner).approve(polygonTokenBridger.address, toWei("1"));

    // Cannot call send on the contract on L1.
    await expect(polygonTokenBridger.connect(owner).send(weth.address, toWei("1"))).to.be.revertedWith(
      "Cannot run method on this chain"
    );
  });

  it("PolygonTokenBridger correctly forwards the exit call", async function () {
    const l1ChainId = await owner.getChainId();

    // Make sure the L1 chain is different from the chainId where this is deployed.
    const l2ChainId = randomBigNumber();

    const polygonTokenBridger = await (
      await getContractFactory("PolygonTokenBridger", owner)
    ).deploy(hubPool.address, polygonRegistry.address, weth.address, weth.address, l1ChainId, l2ChainId);

    // Cannot call send on the contract on L1.
    const exitBytes = "0x" + randomBytes(100).toString("hex");
    await polygonTokenBridger.connect(owner).callExit(exitBytes);

    expect(polygonRegistry.erc20Predicate).to.have.been.calledOnce; // Should call into the registry.
    expect(erc20Predicate.startExitWithBurntTokens).to.have.been.calledOnce; // Should call start exit.
    expect(erc20Predicate.startExitWithBurntTokens).to.have.been.calledWith(exitBytes); // Bytes should have been forwarded.
  });
});
