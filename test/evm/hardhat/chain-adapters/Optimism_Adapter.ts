/* eslint-disable no-unused-expressions */
import {
  amountToLp,
  mockTreeRoot,
  refundProposalLiveness,
  bondAmount,
  mockRelayerRefundRoot,
  mockSlowRelayRoot,
} from "./../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  getContractFactory,
  seedWallet,
  randomAddress,
  createFakeFromABI,
  toWei,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import { CIRCLE_DOMAIN_IDs } from "../../../../deploy/consts";

let hubPool: Contract,
  optimismAdapter: Contract,
  weth: Contract,
  dai: Contract,
  usdc: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let l1CrossDomainMessenger: FakeContract,
  l1StandardBridge: FakeContract,
  cctpMessenger: FakeContract,
  cctpTokenMinter: FakeContract;

const optimismChainId = 10;
const l2Gas = 200000;

describe("Optimism Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, usdc, l2Usdc } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai, usdc], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai, usdc], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai, usdc]);
    for (const token of [weth, dai, usdc]) {
      await token.connect(liquidityProvider).approve(hubPool.address, amountToLp);
      await hubPool.connect(liquidityProvider).addLiquidity(token.address, amountToLp);
      await token.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    }

    l1StandardBridge = await createFake("L1StandardBridge");
    l1CrossDomainMessenger = await createFake("L1CrossDomainMessenger");
    cctpMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));

    optimismAdapter = await (
      await getContractFactory("Optimism_Adapter", owner)
    ).deploy(
      weth.address,
      l1CrossDomainMessenger.address,
      l1StandardBridge.address,
      usdc.address,
      cctpMessenger.address
    );

    await hubPool.setCrossChainContracts(optimismChainId, optimismAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(optimismChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(optimismChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(optimismChainId, usdc.address, l2Usdc);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(optimismChainId, functionCallData))
      .to.emit(optimismAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    expect(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(mockSpoke.address, functionCallData, l2Gas);
  });
  it("Correctly calls appropriate Optimism bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, optimismChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the optimism contracts.
    expect(l1StandardBridge.depositERC20To).to.have.been.calledOnce; // One token transfer over the bridge.
    expect(l1StandardBridge.depositETHTo).to.have.callCount(0); // No ETH transfers over the bridge.
    const expectedErc20L1ToL2BridgeParams = [dai.address, l2Dai, mockSpoke.address, tokensSendToL2, l2Gas, "0x"];
    expect(l1StandardBridge.depositERC20To).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [mockTreeRoot, mockTreeRoot]),
      l2Gas,
    ];
    expect(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(...expectedL2ToL1FunctionCallParams);
  });
  it("Correctly unwraps WETH and bridges ETH", async function () {
    // Cant bridge WETH on optimism. Rather, unwrap WETH to ETH then bridge it. Validate the adapter does this.
    const { leaves, tree } = await constructSingleChainTree(weth.address, 1, optimismChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the optimism contracts.
    expect(l1StandardBridge.depositETHTo).to.have.been.calledOnce; // One eth transfer over the bridge.
    expect(l1StandardBridge.depositERC20To).to.have.callCount(0); // No Token transfers over the bridge.
    expect(l1StandardBridge.depositETHTo).to.have.been.calledWith(mockSpoke.address, l2Gas, "0x");
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [mockTreeRoot, mockTreeRoot]),
      l2Gas,
    ];
    expect(l1CrossDomainMessenger.sendMessage).to.have.been.calledWith(...expectedL2ToL1FunctionCallParams);
  });

  it("Correctly calls the CCTP bridge adapter when attempting to bridge USDC", async function () {
    const internalChainId = optimismChainId;
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, internalChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), mockRelayerRefundRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved gateway to spend its ERC20.
    expect(await usdc.allowance(hubPool.address, cctpMessenger.address)).to.equal(tokensSendToL2);

    // The correct functions should have been called on the bridge contracts
    expect(cctpMessenger.depositForBurn).to.have.been.calledOnce;
    expect(cctpMessenger.depositForBurn).to.have.been.calledWith(
      ethers.BigNumber.from(tokensSendToL2),
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );
  });
});
