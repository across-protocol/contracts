"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const constants_1 = require("./../constants");
const utils_1 = require("../utils");
const utils_2 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, optimismAdapter, mockAdapter, weth, dai, timer, mockSpoke;
let l2Weth, l2Dai;
let owner, dataWorker, liquidityProvider;
let l1CrossDomainMessenger, l1StandardBridge;
const optimismChainId = 10;
let l1ChainId;
describe("Optimism Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, mockAdapter } = await (0,
    HubPool_Fixture_1.hubPoolFixture)());
    l1ChainId = Number(await utils_1.hre.getChainId());
    await (0, utils_2.seedWallet)(dataWorker, [dai], weth, constants_1.amountToLp);
    await (0, utils_2.seedWallet)(liquidityProvider, [dai], weth, constants_1.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, constants_1.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, constants_1.bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, constants_1.amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, constants_1.bondAmount.mul(10));
    l1StandardBridge = await (0, utils_1.createFake)("L1StandardBridge");
    l1CrossDomainMessenger = await (0, utils_1.createFake)("L1CrossDomainMessenger");
    optimismAdapter = await (
      await (0, utils_2.getContractFactory)("Optimism_Adapter", owner)
    ).deploy(weth.address, l1CrossDomainMessenger.address, l1StandardBridge.address);
    await hubPool.setCrossChainContracts(optimismChainId, optimismAdapter.address, mockSpoke.address);
    await hubPool.whitelistRoute(optimismChainId, l1ChainId, l2Weth, weth.address);
    await hubPool.whitelistRoute(optimismChainId, l1ChainId, l2Dai, dai.address);
    await hubPool.setCrossChainContracts(l1ChainId, mockAdapter.address, mockSpoke.address);
    await hubPool.whitelistRoute(l1ChainId, optimismChainId, weth.address, l2Weth);
    await hubPool.whitelistRoute(l1ChainId, optimismChainId, dai.address, l2Dai);
  });
  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = (0, utils_2.randomAddress)();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    (0, utils_1.expect)(await hubPool.relaySpokePoolAdminFunction(optimismChainId, functionCallData))
      .to.emit(optimismAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    (0, utils_1.expect)(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(
      mockSpoke.address,
      functionCallData,
      constants_1.sampleL2Gas
    );
  });
  it("Correctly calls appropriate Optimism bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leafs, tree, tokensSendToL2 } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      dai.address,
      1,
      optimismChainId
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + constants_1.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // The correct functions should have been called on the optimism contracts.
    (0, utils_1.expect)(l1StandardBridge.depositERC20To).to.have.been.calledOnce; // One token transfer over the bridge.
    (0, utils_1.expect)(l1StandardBridge.depositETHTo).to.have.callCount(0); // No ETH transfers over the bridge.
    const expectedErc20L1ToL2BridgeParams = [
      dai.address,
      l2Dai,
      mockSpoke.address,
      tokensSendToL2,
      constants_1.sampleL2Gas,
      "0x",
    ];
    (0, utils_1.expect)(l1StandardBridge.depositERC20To).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [constants_1.mockTreeRoot, constants_1.mockTreeRoot]),
      constants_1.sampleL2Gas,
    ];
    (0, utils_1.expect)(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(
      ...expectedL2ToL1FunctionCallParams
    );
  });
  it("Correctly unwraps WETH and bridges ETH", async function () {
    // Cant bridge WETH on optimism. Rather, unwrap WETH to ETH then bridge it. Validate the adapter does this.
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address, 1, optimismChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + constants_1.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // The correct functions should have been called on the optimism contracts.
    (0, utils_1.expect)(l1StandardBridge.depositETHTo).to.have.been.calledOnce; // One eth transfer over the bridge.
    (0, utils_1.expect)(l1StandardBridge.depositERC20To).to.have.callCount(0); // No Token transfers over the bridge.
    (0, utils_1.expect)(l1StandardBridge.depositETHTo).to.have.been.calledWith(
      mockSpoke.address,
      constants_1.sampleL2Gas,
      "0x"
    );
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [constants_1.mockTreeRoot, constants_1.mockTreeRoot]),
      constants_1.sampleL2Gas,
    ];
    (0, utils_1.expect)(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(
      ...expectedL2ToL1FunctionCallParams
    );
  });
});
