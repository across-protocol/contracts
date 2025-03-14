import { mockTreeRoot, amountToReturn, amountHeldByPool, zeroAddress, TokenRolesEnum } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  toWei,
  getContractFactory,
  seedContract,
  createFakeFromABI,
  addressToBytes,
  createTypedFakeFromABI,
  BigNumber,
  toWeiWithDecimals,
} from "../../../../utils/utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { IHypXERC20Router__factory } from "../../../../typechain";

let hubPool: Contract, optimismSpokePool: Contract, dai: Contract, weth: Contract, l2EzETH: Contract;
let l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let crossDomainMessenger: FakeContract,
  l2StandardBridge: FakeContract,
  l2CctpTokenMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  l2HypXERC20Router: FakeContract;

const l2Eth = "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000";

describe("Optimism Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, l2Usdc } = await hubPoolFixture());

    // Create ezETH token for XERC20 testing
    l2EzETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await l2EzETH.addMember(TokenRolesEnum.MINTER, owner.address);

    // Create the fake at the optimism cross domain messenger and l2StandardBridge pre-deployment addresses.
    crossDomainMessenger = await createFake("L2CrossDomainMessenger", "0x4200000000000000000000000000000000000007");
    l2StandardBridge = await createFake("MockBedrockL2StandardBridge", "0x4200000000000000000000000000000000000010");
    l2CctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    l2CctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));
    l2HypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);

    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: toWei("1") });

    optimismSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("MockOptimism_SpokePool", owner),
      [l2Eth, 0, owner.address, hubPool.address],
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address] }
    );

    await seedContract(optimismSpokePool, relayer, [dai, l2EzETH], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("Optimism_SpokePool", owner),
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address, toWei("1")],
      }
    );

    // upgradeTo fails unless called by cross domain admin via messenger contract
    await expect(optimismSpokePool.connect(rando).upgradeTo(implementation)).to.be.revertedWith("NotCrossChainCall");
    await expect(optimismSpokePool.connect(crossDomainMessenger.wallet).upgradeTo(implementation)).to.be.revertedWith(
      "NotCrossDomainAdmin"
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).upgradeTo(implementation);
  });

  it("Only cross domain owner can set l1GasLimit", async function () {
    await expect(optimismSpokePool.setL1GasLimit(1337)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setL1GasLimit(1337);
    expect(await optimismSpokePool.l1Gas()).to.equal(1337);
  });

  it("Only cross domain owner can set token bridge address for L2 token", async function () {
    await expect(optimismSpokePool.setTokenBridge(l2Dai, rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setTokenBridge(l2Dai, rando.address);
    expect(await optimismSpokePool.tokenBridges(l2Dai)).to.equal(rando.address);
  });

  it("Only cross domain owner can enable a route", async function () {
    await expect(optimismSpokePool.setEnableRoute(l2Dai, 1, true)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setEnableRoute(l2Dai, 1, true);
    expect(await optimismSpokePool.enabledDepositRoutes(l2Dai, 1)).to.equal(true);
  });

  it("Only cross domain owner can set the cross domain admin", async function () {
    await expect(optimismSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setCrossDomainAdmin(rando.address);
    expect(await optimismSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Only cross domain owner can set the hub pool address", async function () {
    await expect(optimismSpokePool.setWithdrawalRecipient(rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setWithdrawalRecipient(rando.address);
    expect(await optimismSpokePool.withdrawalRecipient()).to.equal(rando.address);
  });

  it("Only cross domain owner can initialize a relayer refund", async function () {
    await expect(optimismSpokePool.relayRootBundle(mockTreeRoot, mockTreeRoot)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(mockTreeRoot, mockTreeRoot);
    expect((await optimismSpokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await optimismSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Only owner can delete a relayer refund", async function () {
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(mockTreeRoot, mockTreeRoot);
    await expect(optimismSpokePool.emergencyDeleteRootBundle(0)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await expect(optimismSpokePool.connect(crossDomainMessenger.wallet).emergencyDeleteRootBundle(0)).to.not.be
      .reverted;
    expect((await optimismSpokePool.rootBundles(0)).slowRelayRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
    expect((await optimismSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
  });

  it("Only owner can set a remote L1 token", async function () {
    expect(await optimismSpokePool.remoteL1Tokens(l2Dai)).to.equal(zeroAddress);
    await expect(optimismSpokePool.setRemoteL1Token(l2Dai, rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await expect(optimismSpokePool.connect(crossDomainMessenger.wallet).setRemoteL1Token(l2Dai, rando.address)).to.not
      .be.reverted;
    expect(await optimismSpokePool.remoteL1Tokens(l2Dai)).to.equal(rando.address);
  });

  it("Bridge tokens to hub pool correctly calls the Standard L2 Bridge for ERC20", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2Dai,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await optimismSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(l2StandardBridge.withdrawTo).to.have.been.calledOnce;
    expect(l2StandardBridge.withdrawTo).to.have.been.calledWith(l2Dai, hubPool.address, amountToReturn, 5000000, "0x");
  });
  it("If remote L1 token is set for native L2 token, then bridge calls bridgeERC20To instead of withdrawTo", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);

    // If we set a remote L1 token for the native L2 token, then the bridge should call bridgeERC20To instead of withdrawTo
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setRemoteL1Token(dai.address, rando.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await optimismSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(l2StandardBridge.bridgeERC20To).to.have.been.calledOnce;
    expect(l2StandardBridge.bridgeERC20To).to.have.been.calledWith(
      dai.address,
      rando.address,
      hubPool.address,
      amountToReturn,
      5000000,
      "0x"
    );
  });
  it("Bridge tokens to hub pool correctly calls an alternative L2 Gateway router", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2Dai,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    const altL2Bridge = await createFake("L2StandardBridge");
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setTokenBridge(l2Dai, altL2Bridge.address);
    await optimismSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(altL2Bridge.withdrawTo).to.have.been.calledOnce;
    expect(altL2Bridge.withdrawTo).to.have.been.calledWith(l2Dai, hubPool.address, amountToReturn, 5000000, "0x");
  });
  it("Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH, including unwrap", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      weth.address,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);

    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    // When sending l2Weth we should see two differences from the previous test: 1) there should be a call to l2WETH to
    // unwrap l2WETH to l2ETH. 2) the address in the l2StandardBridge that is withdrawn should no longer be l2WETH but
    // switched to l2ETH as this is what is sent over the canonical Optimism bridge when sending ETH.

    // Executing the refund leaf should cause spoke pool to unwrap WETH to ETH to prepare to send it as msg.value
    // to the L2StandardBridge. This results in a net decrease in WETH balance.
    await expect(() =>
      optimismSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.changeTokenBalance(weth, optimismSpokePool, amountToReturn.mul(-1));
    expect(l2StandardBridge.withdrawTo).to.have.been.calledWithValue(amountToReturn);

    expect(l2StandardBridge.withdrawTo).to.have.been.calledOnce;
    expect(l2StandardBridge.withdrawTo).to.have.been.calledWith(l2Eth, hubPool.address, amountToReturn, 5000000, "0x");
  });

  it("Bridge tokens to hub pool correctly using the Hyperlane XERC20 messaging for ezETH token", async function () {
    // Set up XERC20 router for l2EzETH
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    l2HypXERC20Router.wrappedToken.returns(l2EzETH.address);
    await optimismSpokePool
      .connect(crossDomainMessenger.wallet)
      .setXERC20HypRouter(l2EzETH.address, l2HypXERC20Router.address);
    crossDomainMessenger.xDomainMessageSender.reset();

    const hypXERC20Fee = toWeiWithDecimals("1", 9).mul(200_000); // 1 GWEI gas price * 200,000 gas cost
    l2HypXERC20Router.quoteGasPayment.returns(hypXERC20Fee);

    const ezETHSendAmount = BigNumber.from("1234567000000000000");
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2EzETH.address,
      await optimismSpokePool.callStatic.chainId(),
      ezETHSendAmount
    );

    // Set up admin permission to relay root bundle
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    crossDomainMessenger.xDomainMessageSender.reset();

    await optimismSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: hypXERC20Fee });

    // Adapter should have approved l2HypXERC20Router to spend its ERC20
    expect(await l2EzETH.allowance(optimismSpokePool.address, l2HypXERC20Router.address)).to.equal(ezETHSendAmount);

    const hubPoolHypDomainId = 1;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledWith(
      hubPoolHypDomainId,
      ethers.utils.hexZeroPad(hubPool.address, 32).toLowerCase(),
      ezETHSendAmount
    );
  });
});
