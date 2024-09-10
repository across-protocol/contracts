/* eslint-disable no-unused-expressions */
import * as consts from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  toWei,
  getContractFactory,
  seedWallet,
  randomAddress,
  createFakeFromABI,
} from "../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

const l1GasPriceOracleABI = [
  {
    inputs: [
      {
        internalType: "uint256",
        name: "_gasLimit",
        type: "uint256",
      },
    ],
    name: "estimateCrossDomainMessageFee",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

const l1GatewayRouterABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "_token",
        type: "address",
      },
      {
        internalType: "address",
        name: "_to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "_amount",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "_gasLimit",
        type: "uint256",
      },
    ],
    name: "depositERC20",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "_l1Address",
        type: "address",
      },
    ],
    name: "getL2ERC20Address",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

const l1MessengerABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "_to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "_value",
        type: "uint256",
      },
      {
        internalType: "bytes",
        name: "_message",
        type: "bytes",
      },
      {
        internalType: "uint256",
        name: "_gasLimit",
        type: "uint256",
      },
    ],
    name: "sendMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

/**
 * For equivalency with Smock, we need to use the same BigNumber type.
 * @param value A string or number to convert to a BigNumber
 * @returns A BigNumber
 */
function toBN(value: string | number) {
  return ethers.BigNumber.from(value);
}

let hubPool: Contract, scrollAdapter: Contract, weth: Contract, dai: Contract, mockSpoke: Contract, timer: Contract;
let l2Weth: string, l2Dai: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;
let liquidityProvider: SignerWithAddress;
let l1Messenger: FakeContract, l1GasPriceOracle: FakeContract, l1GatewayRouter: FakeContract;

const scrollChainId = 534351;

describe("Scroll Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [dai], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, consts.amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    l1Messenger = await createFakeFromABI(l1MessengerABI);
    l1GasPriceOracle = await createFakeFromABI(l1GasPriceOracleABI);
    l1GatewayRouter = await createFakeFromABI(l1GatewayRouterABI);

    // We need to set up the mocks to return the correct values for the L1->L2 bridge tokena aliases.
    l1GatewayRouter.getL2ERC20Address.whenCalledWith(dai.address).returns(l2Dai);
    l1GatewayRouter.getL2ERC20Address.whenCalledWith(weth.address).returns(l2Weth);

    scrollAdapter = await (
      await getContractFactory("Scroll_Adapter", owner)
    ).deploy(
      l1GatewayRouter.address,
      l1Messenger.address,
      l1GasPriceOracle.address,
      2_000_000 /* 2M gas limit for arbitrary messages */,
      250_000 /* 250k gas limit for tokens */
    );
    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    await hubPool.setCrossChainContracts(scrollChainId, scrollAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(scrollChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(scrollChainId, weth.address, l2Weth);
  });

  it("relayMessage fails when there's not enough fees", async function () {
    // Hike the relayer fee to something that's too high for our hub pool to pay.
    const fakedRelayerFee = toWei("1").add(1);
    l1GasPriceOracle.estimateCrossDomainMessageFee.returns(fakedRelayerFee);

    // Let's queue up a spoke pool function call and check that it's called correctly.
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);

    // We should expect that this will fail in the spoke adapter. The hub pool should propagate this error
    // to the caller with the error message "delegatecall failed".
    await expect(hubPool.relaySpokePoolAdminFunction(scrollChainId, functionCallData)).to.have.revertedWith(
      "delegatecall failed"
    );
  });

  it("relayMessage calls spoke pool functions", async function () {
    // Let's queue up a spoke pool function call and check that it's called correctly.
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);

    // For additional testing, we can verify that we're relying on the L2Gas Oracle for the relayer fee.
    const fakedRelayerFee = toBN(10_000);
    l1GasPriceOracle.estimateCrossDomainMessageFee.returns(fakedRelayerFee);

    // Execute on the hub pool.
    const hubTxn = await hubPool.relaySpokePoolAdminFunction(scrollChainId, functionCallData);

    // To begin, we're expecting that the relaying fees needed to send this message have bene
    // derrived from `l1GasPriceOracle.estimateCrossDomainMessageFee`.
    await expect(hubTxn).to.changeEtherBalances([l1Messenger], [fakedRelayerFee]);

    // Let's check that the L1->L2 message was sent correctly and that the message
    // was prepared with the correct parameters.
    expect(l1Messenger.sendMessage).to.have.been.calledOnce;
    expect(l1GasPriceOracle.estimateCrossDomainMessageFee).to.have.been.calledOnce;
    expect(l1Messenger.sendMessage).to.have.been.calledWithValue(fakedRelayerFee);
    expect(l1Messenger.sendMessage).to.have.been.calledWith(
      mockSpoke.address,
      toBN(0),
      functionCallData,
      toBN(2_000_000) // This is baked into the adapter.
    );
  });

  it("Correctly calls appropriate scroll bridge functions when transferring tokens to different chains", async function () {
    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.

    // Scroll uses the same gateway for WETH and ERC20s
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, scrollChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    const fakedRelayerFee = toBN(10_000);
    l1GasPriceOracle.estimateCrossDomainMessageFee.returns(fakedRelayerFee);

    const txn = await hubPool
      .connect(dataWorker)
      .executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    expect(l1GatewayRouter.depositERC20).to.have.been.calledOnce;
    expect(l1GatewayRouter.depositERC20).to.have.been.calledWith(
      dai.address,
      mockSpoke.address,
      tokensSendToL2,
      toBN(250_000) // This is baked into the adapter.
    );
    await expect(txn).to.have.changeEtherBalances([l1Messenger], [fakedRelayerFee]);
  });
});
