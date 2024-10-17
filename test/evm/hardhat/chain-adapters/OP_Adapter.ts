/* eslint-disable no-unused-expressions */
import { CHAIN_IDs } from "@across-protocol/constants";
import * as consts from "../constants";
import {
  ethers,
  expect,
  Contract,
  createFake,
  createFakeFromABI,
  FakeContract,
  SignerWithAddress,
  toWei,
  getContractFactory,
  seedWallet,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract, adapter: Contract, weth: Contract, usdc: Contract, mockSpoke: Contract, timer: Contract;
let l2Weth: string, l2Usdc: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;
let liquidityProvider: SignerWithAddress;
let l1CrossDomainMessenger: FakeContract, l1StandardBridge: FakeContract, opUSDCBridge: FakeContract;

const { WORLD_CHAIN } = CHAIN_IDs;
const opUSDCBridgeABI = [
  {
    inputs: [
      { internalType: "address", name: "_to", type: "address" },
      { internalType: "uint256", name: "_amount", type: "uint256" },
      { internalType: "uint32", name: "_minGasLimit", type: "uint32" },
    ],
    name: "sendMessage",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
];

describe("OP Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, l2Weth, usdc, l2Usdc, hubPool, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [usdc], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [usdc], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, usdc]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await usdc.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(usdc.address, consts.amountToLp);
    await usdc.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    l1CrossDomainMessenger = await createFake("L1CrossDomainMessenger");
    l1StandardBridge = await createFake("L1StandardBridge");
    opUSDCBridge = await createFakeFromABI(opUSDCBridgeABI);

    adapter = await (
      await getContractFactory("OP_Adapter", owner)
    ).deploy(
      weth.address,
      usdc.address,
      l1CrossDomainMessenger.address,
      l1StandardBridge.address,
      opUSDCBridge.address
    );
    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    await hubPool.setCrossChainContracts(WORLD_CHAIN, adapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(WORLD_CHAIN, usdc.address, l2Usdc);
    await hubPool.setPoolRebalanceRoute(WORLD_CHAIN, weth.address, l2Weth);
  });

  it("Correctly routes USDC via the configured OP USDC bridge", async function () {
    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, WORLD_CHAIN);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    const l2Gas = await adapter.L2_GAS_LIMIT();
    expect(opUSDCBridge.sendMessage).to.have.been.calledOnce;
    expect(opUSDCBridge.sendMessage).to.have.been.calledWith(mockSpoke.address, tokensSendToL2, l2Gas);
  });
});
