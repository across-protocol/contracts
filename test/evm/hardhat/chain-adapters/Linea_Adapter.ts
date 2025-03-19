import { amountToLp, mockTreeRoot, refundProposalLiveness, bondAmount, TokenRolesEnum } from "../constants";
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
  createTypedFakeFromABI,
  fromWei,
  toBN,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";
import {
  AdapterStore,
  AdapterStore__factory,
  IHypXERC20Router,
  IHypXERC20Router__factory,
} from "../../../../typechain";

let hubPool: Contract,
  lineaAdapter: Contract,
  weth: Contract,
  dai: Contract,
  usdc: Contract,
  ezETH: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let lineaMessageService: FakeContract,
  lineaTokenBridge: FakeContract,
  lineaUsdcBridge: FakeContract,
  adapterStore: FakeContract<AdapterStore>,
  hypXERC20Router: FakeContract<IHypXERC20Router>;

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

const lineaUsdcBridgeAbi = [
  {
    inputs: [
      { internalType: "uint256", name: "amount", type: "uint256" },
      { internalType: "address", name: "to", type: "address" },
    ],
    name: "depositTo",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "usdc",
    outputs: [
      {
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

describe("Linea Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, usdc, l2Weth, l2Dai, l2Usdc, hubPool, mockSpoke, timer } = await hubPoolFixture());

    // Create ezETH token for XERC20 testing
    ezETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await ezETH.addMember(TokenRolesEnum.MINTER, owner.address);
    const l2EzETH = randomAddress();

    await seedWallet(dataWorker, [dai, usdc, ezETH], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai, usdc, ezETH], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai, usdc, ezETH]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await usdc.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(usdc.address, amountToLp);
    await usdc.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await ezETH.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(ezETH.address, amountToLp);
    await ezETH.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    lineaMessageService = await smock.fake(lineaMessageServiceAbi, {
      address: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F",
    });
    lineaTokenBridge = await smock.fake(lineaTokenBridgeAbi, { address: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319" });
    lineaUsdcBridge = await smock.fake(lineaUsdcBridgeAbi, {
      address: "0x504a330327a089d8364c4ab3811ee26976d388ce",
    });
    lineaUsdcBridge.usdc.returns(usdc.address);

    hypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);
    adapterStore = await createTypedFakeFromABI([...AdapterStore__factory.abi]);

    const hypXERC20FeeCap = toWei("1");

    lineaAdapter = await (
      await getContractFactory("Linea_Adapter", owner)
    ).deploy(
      weth.address,
      lineaMessageService.address,
      lineaTokenBridge.address,
      lineaUsdcBridge.address,
      lineaChainId,
      adapterStore.address,
      hypXERC20FeeCap
    );

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("100000") });

    await hubPool.setCrossChainContracts(lineaChainId, lineaAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(lineaChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(lineaChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(lineaChainId, usdc.address, l2Usdc);
    await hubPool.setPoolRebalanceRoute(lineaChainId, ezETH.address, l2EzETH);
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
  it("Correctly calls appropriate bridge functions when making USDC cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, lineaChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the optimism contracts.
    const expectedErc20L1ToL2BridgeParams = [tokensSendToL2, mockSpoke.address];
    expect(lineaUsdcBridge.depositTo).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
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
  it("Correctly calls Hyperlane XERC20 bridge", async function () {
    // Set hyperlane router in adapter store
    hypXERC20Router.wrappedToken.returns(ezETH.address);
    const hypXERC20MessengerType = ethers.utils.formatBytes32String("HYP_XERC20_ROUTER");
    await adapterStore
      .connect(owner)
      .setMessenger(hypXERC20MessengerType, lineaChainId, ezETH.address, hypXERC20Router.address);
    adapterStore.crossChainMessengers
      .whenCalledWith(hypXERC20MessengerType, lineaChainId, ezETH.address)
      .returns(hypXERC20Router.address);

    // construct repayment bundle
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(ezETH.address, 1, lineaChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    hypXERC20Router.quoteGasPayment.returns(toBN(1e9).mul(200_000));

    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved gateway to spend its ERC20.
    expect(await ezETH.allowance(hubPool.address, hypXERC20Router.address)).to.equal(tokensSendToL2);

    // source https://github.com/hyperlane-xyz/hyperlane-registry
    const lineaDstDomainId = 59144;

    // We should have called send on the oftMessenger once with correct params
    expect(hypXERC20Router.quoteGasPayment).to.have.been.calledOnce;
    expect(hypXERC20Router.quoteGasPayment).to.have.been.calledWith(lineaDstDomainId);

    expect(hypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(hypXERC20Router.transferRemote).to.have.been.calledWith(
      lineaDstDomainId,
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      tokensSendToL2
    );
  });
});
