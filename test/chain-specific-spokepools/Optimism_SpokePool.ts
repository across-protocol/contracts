import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress, createFake, toWei } from "../utils";
import { getContractFactory, seedContract, hre } from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, optimismSpokePool: Contract, timer: Contract, dai: Contract, weth: Contract;
let l2Dai: string;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let crossDomainMessenger: FakeContract, l2StandardBridge: FakeContract, l2Weth: FakeContract;

describe("Optimism Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, timer } = await hubPoolFixture());

    // Create the fake at the optimism cross domain messenger and l2StandardBridge pre-deployment addresses.
    crossDomainMessenger = await createFake("L2CrossDomainMessenger", "0x4200000000000000000000000000000000000007");
    l2StandardBridge = await createFake("L2StandardBridge", "0x4200000000000000000000000000000000000010");

    // Set l2Weth to the address deployed on the optimism predeploy.
    l2Weth = await createFake("WETH9", "0x4200000000000000000000000000000000000006");

    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: toWei("1") });

    optimismSpokePool = await (
      await getContractFactory("Optimism_SpokePool", owner)
    ).deploy(owner.address, hubPool.address, timer.address);

    await seedContract(optimismSpokePool, relayer, [dai], weth, amountHeldByPool);
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
    await expect(optimismSpokePool.setHubPool(rando.address)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setHubPool(rando.address);
    expect(await optimismSpokePool.hubPool()).to.equal(rando.address);
  });

  it("Only cross domain owner can set the quote time buffer", async function () {
    await expect(optimismSpokePool.setDepositQuoteTimeBuffer(12345)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setDepositQuoteTimeBuffer(12345);
    expect(await optimismSpokePool.depositQuoteTimeBuffer()).to.equal(12345);
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
      l2Weth.address,
      await optimismSpokePool.callStatic.chainId()
    );
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await optimismSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // When sending l2Weth we should see two differences from the previous test: 1) there should be a call to l2WETH to
    // unwrap l2WETH to l2ETH. 2) the address in the l2StandardBridge that is withdrawn should no longer be l2WETH but
    // switched to l2ETH as this is what is sent over the canonical Optimism bridge when sending ETH.
    expect(l2Weth.withdraw).to.have.been.calledOnce;
    expect(l2Weth.withdraw).to.have.been.calledWith(amountToReturn);
    expect(l2StandardBridge.withdrawTo).to.have.been.calledOnce;
    const l2Eth = "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000";
    expect(l2StandardBridge.withdrawTo).to.have.been.calledWith(l2Eth, hubPool.address, amountToReturn, 5000000, "0x");
  });
});
