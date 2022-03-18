import { amountToLp, mockTreeRoot, refundProposalLiveness, bondAmount, mockSlowRelayRoot } from "./../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress } from "../utils";
import { createFake, getContractFactory, seedWallet, randomAddress, hre } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract,
  polygonAdapter: Contract,
  mockAdapter: Contract,
  weth: Contract,
  dai: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let rootChainManager: FakeContract, fxStateSender: FakeContract;

const polygonChainId = 137;
let l1ChainId: number;

describe("Polygon Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, mockAdapter } = await hubPoolFixture());
    l1ChainId = Number(await hre.getChainId());
    await seedWallet(dataWorker, [dai], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    rootChainManager = await createFake("RootChainManagerMock");
    fxStateSender = await createFake("FxStateSenderMock");

    polygonAdapter = await (
      await getContractFactory("Polygon_Adapter", owner)
    ).deploy(rootChainManager.address, fxStateSender.address, weth.address);

    await hubPool.setCrossChainContracts(polygonChainId, polygonAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(polygonChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(polygonChainId, dai.address, l2Dai);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(polygonChainId, functionCallData))
      .to.emit(polygonAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);

    expect(fxStateSender.sendMessageToChild).to.have.been.calledWith(mockSpoke.address, functionCallData);
  });
  it("Correctly calls appropriate Polygon bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, polygonChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the polygon contracts.
    expect(rootChainManager.depositFor).to.have.been.calledOnce; // One token transfer over the bridge.
    expect(rootChainManager.depositEtherFor).to.have.callCount(0); // No ETH transfers over the bridge.

    const expectedErc20L1ToL2BridgeParams = [
      mockSpoke.address,
      dai.address,
      ethers.utils.defaultAbiCoder.encode(["uint256"], [tokensSendToL2]),
    ];
    expect(rootChainManager.depositFor).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
    const expectedL1ToL2FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [mockTreeRoot, mockSlowRelayRoot]),
    ];
    expect(fxStateSender.sendMessageToChild).to.have.been.calledWith(...expectedL1ToL2FunctionCallParams);
  });
  it("Correctly unwraps WETH and bridges ETH", async function () {
    // Cant bridge WETH on polygon. Rather, unwrap WETH to ETH then bridge it. Validate the adapter does this.
    const { leaves, tree } = await constructSingleChainTree(weth.address, 1, polygonChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the polygon contracts.
    expect(rootChainManager.depositEtherFor).to.have.been.calledOnce; // One eth transfer over the bridge.
    expect(rootChainManager.depositFor).to.have.callCount(0); // No Token transfers over the bridge.
    expect(rootChainManager.depositEtherFor).to.have.been.calledWith(mockSpoke.address);
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [mockTreeRoot, mockSlowRelayRoot]),
    ];
    expect(fxStateSender.sendMessageToChild).to.have.been.calledWith(...expectedL2ToL1FunctionCallParams);
  });
});
