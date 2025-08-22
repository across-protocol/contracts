/* eslint-disable no-unused-expressions */
import {
  amountToLp,
  mockTreeRoot,
  refundProposalLiveness,
  bondAmount,
  mockSlowRelayRoot,
  mockRelayerRefundRoot,
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
  getOftEid,
  createTypedFakeFromABI,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { TokenRolesEnum } from "@uma/common";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import {
  IOFT,
  MessagingFeeStructOutput,
  MessagingReceiptStructOutput,
  OFTReceiptStructOutput,
  SendParamStruct,
} from "../../../../typechain/contracts/interfaces/IOFT";
import { IOFT__factory } from "../../../../typechain/factories/contracts/interfaces/IOFT__factory";
import { CIRCLE_DOMAIN_IDs } from "../../../../deploy/consts";
import { AdapterStore, AdapterStore__factory } from "../../../../typechain";
import { CHAIN_IDs } from "@across-protocol/constants";

let hubPool: Contract,
  polygonAdapter: Contract,
  weth: Contract,
  dai: Contract,
  usdc: Contract,
  usdt: Contract,
  matic: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string, l2WMatic: string, l2Usdc: string, l2Usdt: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let rootChainManager: FakeContract,
  fxStateSender: FakeContract,
  depositManager: FakeContract,
  cctpMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  erc20Predicate: string,
  oftMessenger: FakeContract<IOFT>,
  adapterStore: FakeContract<AdapterStore>;
const polygonChainId = CHAIN_IDs.POLYGON;
const oftArbitrumEid = getOftEid(polygonChainId);

describe("Polygon Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, usdc, l2Usdc, usdt, l2Usdt } = await hubPoolFixture());

    matic = await (await getContractFactory("ExpandedERC20", owner)).deploy("Matic", "MATIC", 18);
    await matic.addMember(TokenRolesEnum.MINTER, owner.address);
    l2WMatic = randomAddress();

    await seedWallet(dataWorker, [dai, matic, usdc, usdt], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai, matic, usdc, usdt], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai, matic, usdc, usdt]);
    for (const token of [weth, dai, matic, usdc, usdt]) {
      await token.connect(liquidityProvider).approve(hubPool.address, amountToLp);
      await hubPool.connect(liquidityProvider).addLiquidity(token.address, amountToLp);
      await token.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    }

    rootChainManager = await createFake("RootChainManagerMock");
    fxStateSender = await createFake("FxStateSenderMock");
    depositManager = await createFake("DepositManagerMock");
    erc20Predicate = randomAddress();
    cctpMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));

    oftMessenger = await createTypedFakeFromABI([...IOFT__factory.abi]);
    adapterStore = await createTypedFakeFromABI([...AdapterStore__factory.abi]);
    const oftFeeCap = toWei("1");

    polygonAdapter = await (
      await getContractFactory("Polygon_Adapter", owner)
    ).deploy(
      rootChainManager.address,
      fxStateSender.address,
      depositManager.address,
      erc20Predicate,
      matic.address,
      weth.address,
      usdc.address,
      cctpMessenger.address,
      adapterStore.address,
      oftArbitrumEid,
      oftFeeCap
    );

    await hubPool.setCrossChainContracts(polygonChainId, polygonAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(polygonChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(polygonChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(polygonChainId, matic.address, l2WMatic);
    await hubPool.setPoolRebalanceRoute(polygonChainId, usdc.address, l2Usdc);
    await hubPool.setPoolRebalanceRoute(polygonChainId, usdt.address, l2Usdt);
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

  it("Correctly bridges matic", async function () {
    // Cant bridge WETH on polygon. Rather, unwrap WETH to ETH then bridge it. Validate the adapter does this.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(matic.address, 1, polygonChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the polygon contracts.
    expect(depositManager.depositERC20ForUser).to.have.been.calledOnce; // Should call into the plasma bridge
    expect(depositManager.depositERC20ForUser).to.have.been.calledWith(
      matic.address,
      mockSpoke.address,
      tokensSendToL2
    );
    expect(rootChainManager.depositFor).to.have.callCount(0); // No PoS calls.
    expect(rootChainManager.depositEtherFor).to.have.callCount(0); // No PoS calls.
    const expectedL2ToL1FunctionCallParams = [
      mockSpoke.address,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [mockTreeRoot, mockSlowRelayRoot]),
    ];
    expect(fxStateSender.sendMessageToChild).to.have.been.calledWith(...expectedL2ToL1FunctionCallParams);
  });

  it("Correctly calls the CCTP bridge adapter when attempting to bridge USDC", async function () {
    const internalChainId = polygonChainId;
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

  it("Correctly calls the OFT bridge adapter when attempting to bridge USDT", async function () {
    const internalChainId = polygonChainId;

    // Ensure HubPool has ETH balance to pay native OFT fee if needed
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    // Configure AdapterStore to return OFT messenger for USDT
    oftMessenger.token.returns(usdt.address);

    const oftMessengerType = ethers.utils.formatBytes32String("OFT_MESSENGER");
    await adapterStore
      .connect(owner)
      .setMessenger(oftMessengerType, oftArbitrumEid, usdt.address, oftMessenger.address);
    adapterStore.crossChainMessengers
      .whenCalledWith(oftMessengerType, oftArbitrumEid, usdt.address)
      .returns(oftMessenger.address);

    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdt.address, 1, internalChainId, 6);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), mockRelayerRefundRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    // Mock OFT fees and send receipts
    const msgFeeStruct: MessagingFeeStructOutput = [toWei("0"), ethers.BigNumber.from(0)] as MessagingFeeStructOutput;
    oftMessenger.quoteSend.returns(msgFeeStruct);

    const msgReceipt: MessagingReceiptStructOutput = [
      ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      ethers.BigNumber.from("1"),
      msgFeeStruct,
    ] as MessagingReceiptStructOutput;
    const oftReceipt: OFTReceiptStructOutput = [tokensSendToL2, tokensSendToL2] as OFTReceiptStructOutput;
    oftMessenger.send.returns([msgReceipt, oftReceipt]);

    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved OFT messenger to spend USDT from HubPool
    expect(await usdt.allowance(hubPool.address, oftMessenger.address)).to.equal(tokensSendToL2);

    const sendParam: SendParamStruct = {
      dstEid: oftArbitrumEid,
      to: ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      amountLD: tokensSendToL2,
      minAmountLD: tokensSendToL2,
      extraOptions: "0x",
      composeMsg: "0x",
      oftCmd: "0x",
    };

    // We should have called send on the OFT messenger once with correct params
    expect(oftMessenger.send).to.have.been.calledOnce;
    expect(oftMessenger.send).to.have.been.calledWith(sendParam, msgFeeStruct, hubPool.address);
  });
});
