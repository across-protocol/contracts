import { smock } from "@defi-wonderland/smock";

import { amountToLp, mockTreeRoot, refundProposalLiveness, bondAmount, zeroAddress } from "../constants";
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
} from "../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract,
  polygonZkEvmAdapter: Contract,
  weth: Contract,
  dai: Contract,
  timer: Contract,
  mockSpoke: Contract;
let l2Weth: string, l2Dai: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let polygonZkEvmBridge: FakeContract;

const polygonZkEvmChainId = 1101;
const polygonZkEvmL2NetworkId = 1;

const polygonZkEvmBridgeAbi = [
  {
    inputs: [
      { internalType: "uint32", name: "destinationNetwork", type: "uint32" },
      { internalType: "address", name: "destinationAddress", type: "address" },
      { internalType: "uint256", name: "amount", type: "uint256" },
      { internalType: "address", name: "token", type: "address" },
      { internalType: "bool", name: "forceUpdateGlobalExitRoot", type: "bool" },
      { internalType: "bytes", name: "permitData", type: "bytes" },
    ],
    name: "bridgeAsset",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint32", name: "destinationNetwork", type: "uint32" },
      { internalType: "address", name: "destinationAddress", type: "address" },
      { internalType: "bool", name: "forceUpdateGlobalExitRoot", type: "bool" },
      { internalType: "bytes", name: "metadata", type: "bytes" },
    ],
    name: "bridgeMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

describe("Polygon zkEVM Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    polygonZkEvmBridge = await smock.fake(polygonZkEvmBridgeAbi, {
      address: "0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe",
    });

    polygonZkEvmAdapter = await (
      await getContractFactory("PolygonZkEVM_Adapter", owner)
    ).deploy(weth.address, polygonZkEvmBridge.address);

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("100000") });

    await hubPool.setCrossChainContracts(polygonZkEvmChainId, polygonZkEvmAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(polygonZkEvmChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(polygonZkEvmChainId, dai.address, l2Dai);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(polygonZkEvmChainId, functionCallData))
      .to.emit(polygonZkEvmAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    expect(polygonZkEvmBridge.bridgeMessage).to.have.been.calledWith(
      polygonZkEvmL2NetworkId,
      mockSpoke.address,
      true,
      functionCallData
    );
    expect(polygonZkEvmBridge.bridgeMessage).to.have.been.calledWithValue(BigNumber.from(0));
  });

  it("Correctly calls appropriate bridge functions when making WETH cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(weth.address, 1, polygonZkEvmChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([polygonZkEvmChainId], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    expect(polygonZkEvmBridge.bridgeAsset).to.have.been.calledWith(
      polygonZkEvmL2NetworkId,
      mockSpoke.address,
      tokensSendToL2,
      zeroAddress,
      true,
      "0x"
    );
  });

  it("Correctly calls appropriate bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, polygonZkEvmChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([polygonZkEvmChainId], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    expect(polygonZkEvmBridge.bridgeAsset).to.have.been.calledWith(
      polygonZkEvmL2NetworkId,
      mockSpoke.address,
      tokensSendToL2,
      dai.address,
      true,
      "0x"
    );
  });
});
