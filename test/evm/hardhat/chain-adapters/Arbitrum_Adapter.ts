/* eslint-disable no-unused-expressions */
import * as consts from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  toWei,
  defaultAbiCoder,
  toBN,
  getContractFactory,
  seedWallet,
  randomAddress,
  createFakeFromABI,
  createTypedFakeFromABI,
  BigNumber,
  randomBytes32,
  toWeiWithDecimals,
} from "../../../../utils/utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import {
  IOFT,
  MessagingFeeStructOutput,
  MessagingReceiptStructOutput,
  OFTReceiptStructOutput,
  SendParamStruct,
} from "../../../../typechain/@layerzerolabs/oft-evm/contracts/interfaces/IOFT";
import { IOFT__factory } from "../../../../typechain/factories/@layerzerolabs/oft-evm/contracts/interfaces/IOFT__factory";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { CIRCLE_DOMAIN_IDs } from "../../../../deploy/consts";
import { OFTAddressBook, OFTAddressBook__factory } from "../../../../typechain";

let hubPool: Contract,
  arbitrumAdapter: Contract,
  weth: Contract,
  dai: Contract,
  usdc: Contract,
  usdt: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string, gatewayAddress: string, l2Usdc: string, l2Usdt: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;
let liquidityProvider: SignerWithAddress, refundAddress: SignerWithAddress;
let l1ERC20GatewayRouter: FakeContract,
  l1Inbox: FakeContract,
  cctpMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  oftMessenger: FakeContract<IOFT>,
  oftAddressBook: FakeContract<OFTAddressBook>;

const arbitrumChainId = 42161;

describe("Arbitrum Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider, refundAddress] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, usdc, l2Usdc, usdt, l2Usdt } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai, usdc, usdt], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [dai, usdc, usdt], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai, usdc, usdt]);
    for (const token of [weth, dai, usdc, usdt]) {
      await token.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
      await hubPool.connect(liquidityProvider).addLiquidity(token.address, consts.amountToLp);
      await token.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    }

    cctpMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));

    oftMessenger = await createTypedFakeFromABI([...IOFT__factory.abi]);
    oftAddressBook = await createTypedFakeFromABI([...OFTAddressBook__factory.abi]);
    await oftAddressBook.connect(owner).setOFTMessenger(usdt.address, oftMessenger.address);

    l1Inbox = await createFake("Inbox");
    l1ERC20GatewayRouter = await createFake("ArbitrumMockErc20GatewayRouter");
    gatewayAddress = randomAddress();
    l1ERC20GatewayRouter.getGateway.returns(gatewayAddress);

    arbitrumAdapter = await (
      await getContractFactory("Arbitrum_Adapter", owner)
    ).deploy(
      l1Inbox.address,
      l1ERC20GatewayRouter.address,
      refundAddress.address,
      usdc.address,
      cctpMessenger.address,
      oftAddressBook.address
    );

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    await hubPool.setCrossChainContracts(arbitrumChainId, arbitrumAdapter.address, mockSpoke.address);

    await hubPool.setPoolRebalanceRoute(arbitrumChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(arbitrumChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(arbitrumChainId, usdc.address, l2Usdc);
    await hubPool.setPoolRebalanceRoute(arbitrumChainId, usdt.address, l2Usdt);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);

    expect(await hubPool.relaySpokePoolAdminFunction(arbitrumChainId, functionCallData)).to.changeEtherBalances(
      [l1Inbox],
      [toBN(consts.sampleL2MaxSubmissionCost).add(toBN(consts.sampleL2Gas).mul(consts.sampleL2GasPrice))]
    );
    expect(l1Inbox.createRetryableTicket).to.have.been.calledOnce;
    expect(l1Inbox.createRetryableTicket).to.have.been.calledWith(
      mockSpoke.address,
      0,
      consts.sampleL2MaxSubmissionCost,
      refundAddress.address,
      refundAddress.address,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      functionCallData
    );
  });
  it("Correctly calls appropriate arbitrum bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, arbitrumChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    expect(
      await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]))
    ).to.changeEtherBalances(
      [l1ERC20GatewayRouter],
      [toBN(consts.sampleL2MaxSubmissionCost).add(toBN(consts.sampleL2Gas).mul(consts.sampleL2GasPrice))]
    );

    // The correct functions should have been called on the arbitrum contracts.
    expect(l1ERC20GatewayRouter.outboundTransferCustomRefund).to.have.been.calledOnce; // One token transfer over the canonical bridge.

    // Adapter should have approved gateway to spend its ERC20.
    expect(await dai.allowance(hubPool.address, gatewayAddress)).to.equal(tokensSendToL2);

    const message = defaultAbiCoder.encode(["uint256", "bytes"], [consts.sampleL2MaxSubmissionCost, "0x"]);
    expect(l1ERC20GatewayRouter.outboundTransferCustomRefund).to.have.been.calledWith(
      dai.address,
      refundAddress.address,
      mockSpoke.address,
      tokensSendToL2,
      consts.sampleL2GasSendTokens,
      consts.sampleL2GasPrice,
      message
    );
    expect(l1Inbox.createRetryableTicket).to.have.been.calledOnce; // only 1 L1->L2 message sent.
    expect(l1Inbox.createRetryableTicket).to.have.been.calledWith(
      mockSpoke.address,
      0,
      consts.sampleL2MaxSubmissionCost,
      refundAddress.address,
      refundAddress.address,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
      ])
    );
  });

  it("Correctly calls the CCTP bridge adapter when attempting to bridge USDC", async function () {
    const internalChainId = arbitrumChainId;
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, internalChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
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
  it("Splits USDC into parts to stay under per-message limit when attempting to bridge USDC", async function () {
    const internalChainId = arbitrumChainId;
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, internalChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);

    // 1) Set limit below amount to send and where amount does not divide evenly into limit.
    let newLimit = tokensSendToL2.div(2).sub(1);
    cctpTokenMinter.burnLimitsPerMessage.returns(newLimit);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the bridge contracts
    expect(cctpMessenger.depositForBurn).to.have.been.calledThrice;
    expect(cctpMessenger.depositForBurn.atCall(0)).to.have.been.calledWith(
      newLimit,
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );
    expect(cctpMessenger.depositForBurn.atCall(1)).to.have.been.calledWith(
      newLimit,
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );
    expect(cctpMessenger.depositForBurn.atCall(2)).to.have.been.calledWith(
      2, // each of the above calls left a remainder of 1
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );

    // 2) Set limit below amount to send and where amount divides evenly into limit.
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);

    newLimit = tokensSendToL2.div(2);
    cctpTokenMinter.burnLimitsPerMessage.returns(newLimit);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // 2 more calls added to prior 3.
    expect(cctpMessenger.depositForBurn).to.have.callCount(5);
    expect(cctpMessenger.depositForBurn.atCall(3)).to.have.been.calledWith(
      newLimit,
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );
    expect(cctpMessenger.depositForBurn.atCall(4)).to.have.been.calledWith(
      newLimit,
      CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address
    );
  });
  it("Correctly calls the OFT bridge adapter when attempting to bridge USDT", async function () {
    const internalChainId = arbitrumChainId;

    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdt.address, 1, internalChainId, 6);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);

    // set up correct messenger to be returned on a proper `oftMessengers` call
    oftAddressBook.oftMessengers.whenCalledWith(usdt.address).returns(oftMessenger.address);

    // set up `quoteSend` return val
    const msgFeeStruct: MessagingFeeStructOutput = [
      toWeiWithDecimals("1", 9).mul(200_000), // nativeFee: 1 GWEI gas price * 200,000 gas cost
      BigNumber.from(0), // lzTokenFee: 0
    ] as MessagingFeeStructOutput;
    oftMessenger.quoteSend.returns(msgFeeStruct);

    // set up `send` return val
    const msgReceipt: MessagingReceiptStructOutput = [
      randomBytes32(), // guid
      BigNumber.from("1"), // nonce
      msgFeeStruct, // fee
    ] as MessagingReceiptStructOutput;

    const oftReceipt: OFTReceiptStructOutput = [tokensSendToL2, tokensSendToL2] as OFTReceiptStructOutput;

    oftMessenger.send.returns([msgReceipt, oftReceipt]);

    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved gateway to spend its ERC20.
    expect(await usdt.allowance(hubPool.address, oftMessenger.address)).to.equal(tokensSendToL2);

    // source https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    const arbitrumDstEId = 30110;
    const sendParam: SendParamStruct = {
      dstEid: arbitrumDstEId,
      to: ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      amountLD: tokensSendToL2,
      minAmountLD: tokensSendToL2,
      extraOptions: "0x",
      composeMsg: "0x",
      oftCmd: "0x",
    };

    // We should have called send on the oftMessenger once with correct params
    expect(oftMessenger.send).to.have.been.calledOnce;
    expect(oftMessenger.send).to.have.been.calledWith(sendParam, msgFeeStruct, hubPool.address);
  });
});
