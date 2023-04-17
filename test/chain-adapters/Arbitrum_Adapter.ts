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
} from "../../utils/utils";
import { getContractFactory, seedWallet, randomAddress } from "../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract, arbitrumAdapter: Contract, weth: Contract, dai: Contract, timer: Contract, mockSpoke: Contract;
let l2Weth: string, l2Dai: string, gatewayAddress: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let l1ERC20GatewayRouter: FakeContract, l1Inbox: FakeContract;

const arbitrumChainId = 42161;

describe("Arbitrum Chain Adapter", function () {
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

    l1Inbox = await createFake("Inbox");
    l1ERC20GatewayRouter = await createFake("ArbitrumMockErc20GatewayRouter");
    gatewayAddress = randomAddress();
    l1ERC20GatewayRouter.getGateway.returns(gatewayAddress);

    arbitrumAdapter = await (
      await getContractFactory("Arbitrum_Adapter", owner)
    ).deploy(l1Inbox.address, l1ERC20GatewayRouter.address);

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    await hubPool.setCrossChainContracts(arbitrumChainId, arbitrumAdapter.address, mockSpoke.address);

    await hubPool.setPoolRebalanceRoute(arbitrumChainId, dai.address, l2Dai);
    await hubPool.setPoolRebalanceRoute(arbitrumChainId, weth.address, l2Weth);
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
      "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010",
      "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010",
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
      "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010",
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
      "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010",
      "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010",
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
      ])
    );
  });
});
