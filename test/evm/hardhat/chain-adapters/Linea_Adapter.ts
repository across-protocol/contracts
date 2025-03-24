import {
  amountToLp,
  mockTreeRoot,
  refundProposalLiveness,
  bondAmount,
  mockRelayerRefundRoot,
  mockSlowRelayRoot,
} from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedWallet,
  randomAddress,
  toWei,
  BigNumber,
  createFakeFromABI,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";
import { CCTPTokenV2MessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import { CIRCLE_DOMAIN_IDs } from "../../../../deploy/consts";

let hubPool: Contract,
  lineaAdapter: Contract,
  weth: Contract,
  dai: Contract,
  usdc: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let lineaMessageService: FakeContract, lineaTokenBridge: FakeContract;
let cctpMessenger: FakeContract, cctpTokenMinter: FakeContract;

const lineaChainId = 59144;

const lineaMessageServiceAbi = [
  {
    inputs: [
      { internalType: "address", name: "_to", type: "address" },
      { internalType: "uint256", name: "_fee", type: "uint256" },
      { internalType: "bytes", name: "_calldata", type: "bytes" },
    ],
    name: "sendMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

const lineaTokenBridgeAbi = [
  {
    inputs: [
      { internalType: "address", name: "_token", type: "address" },
      { internalType: "uint256", name: "_amount", type: "uint256" },
      { internalType: "address", name: "_recipient", type: "address" },
    ],
    name: "bridgeToken",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

describe("Linea Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, usdc, l2Weth, l2Dai, l2Usdc, hubPool, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai, usdc], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai, usdc], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai, usdc]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await usdc.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(usdc.address, amountToLp);
    await usdc.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    cctpMessenger = await createFakeFromABI(CCTPTokenV2MessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpMessenger.feeRecipient.returns(owner.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));
    lineaMessageService = await smock.fake(lineaMessageServiceAbi, {
      address: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F",
    });
    lineaTokenBridge = await smock.fake(lineaTokenBridgeAbi, { address: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319" });

    lineaAdapter = await (
      await getContractFactory("Linea_Adapter", owner)
    ).deploy(weth.address, lineaMessageService.address, lineaTokenBridge.address, usdc.address, cctpMessenger.address);

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("100000") });

    await hubPool.setCrossChainContracts(lineaChainId, lineaAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(lineaChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(lineaChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(lineaChainId, usdc.address, l2Usdc);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(lineaChainId, functionCallData))
      .to.emit(lineaAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    expect(lineaMessageService.sendMessage).to.have.been.calledWith(mockSpoke.address, 0, functionCallData);
    expect(lineaMessageService.sendMessage).to.have.been.calledWithValue(BigNumber.from(0));
  });
  it("Correctly calls appropriate bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, lineaChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the optimism contracts.
    const expectedErc20L1ToL2BridgeParams = [dai.address, tokensSendToL2, mockSpoke.address];
    expect(lineaTokenBridge.bridgeToken).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
  });
  it("Correctly calls the CCTP bridge adapter when attempting to bridge USDC", async function () {
    const internalChainId = lineaChainId;
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
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );
  });
  it("Splits USDC into parts to stay under per-message limit when attempting to bridge USDC", async function () {
    const internalChainId = lineaChainId;
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, internalChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), mockRelayerRefundRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    // 1) Set limit below amount to send and where amount does not divide evenly into limit.
    let newLimit = tokensSendToL2.div(2).sub(1);
    cctpTokenMinter.burnLimitsPerMessage.returns(newLimit);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the bridge contracts
    expect(cctpMessenger.depositForBurn).to.have.been.calledThrice;
    expect(cctpMessenger.depositForBurn.atCall(0)).to.have.been.calledWith(
      newLimit,
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );
    expect(cctpMessenger.depositForBurn.atCall(1)).to.have.been.calledWith(
      newLimit,
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );
    expect(cctpMessenger.depositForBurn.atCall(2)).to.have.been.calledWith(
      2, // each of the above calls left a remainder of 1
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );

    // 2) Set limit below amount to send and where amount divides evenly into limit.
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), mockRelayerRefundRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    newLimit = tokensSendToL2.div(2);
    cctpTokenMinter.burnLimitsPerMessage.returns(newLimit);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // 2 more calls added to prior 3.
    expect(cctpMessenger.depositForBurn).to.have.callCount(5);
    expect(cctpMessenger.depositForBurn.atCall(3)).to.have.been.calledWith(
      newLimit,
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );
    expect(cctpMessenger.depositForBurn.atCall(4)).to.have.been.calledWith(
      newLimit,
      // TODO: Change this once we have the actual Linea domain ID
      11, // CIRCLE_DOMAIN_IDs[internalChainId],
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      usdc.address,
      ethers.constants.HashZero,
      ethers.BigNumber.from(0),
      2000
    );
  });
  it("Correctly unwraps WETH and bridges ETH", async function () {
    const { leaves, tree } = await constructSingleChainTree(weth.address, 1, lineaChainId);

    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    // Since WETH is used as proposal bond, the bond plus the WETH are debited from the HubPool's balance.
    // The WETH used in the Linea_Adapter is withdrawn to ETH and then paid to the Linea MessageService.
    const proposalBond = await hubPool.bondAmount();
    await expect(() =>
      hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]))
    ).to.changeTokenBalance(weth, hubPool, leaves[0].netSendAmounts[0].add(proposalBond).mul(-1));
    expect(lineaMessageService.sendMessage).to.have.been.calledWith(mockSpoke.address, 0, "0x");
    expect(lineaMessageService.sendMessage).to.have.been.calledWithValue(leaves[0].netSendAmounts[0]);
  });
});
