import * as consts from "../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress, createFake, toWei } from "../utils";
import { getContractFactory, seedWallet } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract, arbitrumAdapter: Contract, weth: Contract, dai: Contract, timer: Contract, mockSpoke: Contract;
let l2Weth: string, l2Dai: string;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let l1ERC20Gateway: FakeContract, l1Inbox: FakeContract;

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
    l1ERC20Gateway = await createFake("TokenGateway");

    arbitrumAdapter = await (
      await getContractFactory("Arbitrum_Adapter", owner)
    ).deploy(hubPool.address, l1Inbox.address, l1ERC20Gateway.address);

    // Seed the Arbitrum adapter with some funds so it can send L1->L2 messages.
    await liquidityProvider.sendTransaction({ to: arbitrumAdapter.address, value: toWei("1") });

    await hubPool.setCrossChainContracts(arbitrumChainId, arbitrumAdapter.address, mockSpoke.address);

    await hubPool.whitelistRoute(arbitrumChainId, weth.address, l2Weth);

    await hubPool.whitelistRoute(arbitrumChainId, dai.address, l2Dai);
  });

  it("Only owner can set l2GasValues", async function () {
    expect(await arbitrumAdapter.callStatic.l2GasLimit()).to.equal(consts.sampleL2Gas);
    await expect(arbitrumAdapter.connect(liquidityProvider).setL2GasLimit(consts.sampleL2Gas + 1)).to.be.reverted;
    await arbitrumAdapter.connect(owner).setL2GasLimit(consts.sampleL2Gas + 1);
    expect(await arbitrumAdapter.callStatic.l2GasLimit()).to.equal(consts.sampleL2Gas + 1);
  });

  it("Only owner can set l2MaxSubmissionCost", async function () {
    expect(await arbitrumAdapter.callStatic.l2MaxSubmissionCost()).to.equal(consts.sampleL2MaxSubmissionCost);
    await expect(arbitrumAdapter.connect(liquidityProvider).setL2MaxSubmissionCost(consts.sampleL2Gas + 1)).to.be
      .reverted;
    await arbitrumAdapter.connect(owner).setL2MaxSubmissionCost(consts.sampleL2Gas + 1);
    expect(await arbitrumAdapter.callStatic.l2MaxSubmissionCost()).to.equal(consts.sampleL2Gas + 1);
  });

  it("Only owner can set l2GasPrice", async function () {
    expect(await arbitrumAdapter.callStatic.l2GasPrice()).to.equal(consts.sampleL2GasPrice);
    await expect(arbitrumAdapter.connect(liquidityProvider).setL2GasPrice(consts.sampleL2Gas + 1)).to.be.reverted;
    await arbitrumAdapter.connect(owner).setL2GasPrice(consts.sampleL2Gas + 1);
    expect(await arbitrumAdapter.callStatic.l2GasPrice()).to.equal(consts.sampleL2Gas + 1);
  });

  it("Only owner can set l2RefundL2Address", async function () {
    expect(await arbitrumAdapter.callStatic.l2RefundL2Address()).to.equal(owner.address);
    await expect(arbitrumAdapter.connect(liquidityProvider).setL2RefundL2Address(liquidityProvider.address)).to.be
      .reverted;
    await arbitrumAdapter.connect(owner).setL2RefundL2Address(liquidityProvider.address);
    expect(await arbitrumAdapter.callStatic.l2RefundL2Address()).to.equal(liquidityProvider.address);
  });
  it("Correctly calls appropriate arbitrum bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leafs, tree, tokensSendToL2 } = await constructSingleChainTree(dai, 1, arbitrumChainId);
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockDestinationDistributionRoot, consts.mockSlowRelayFulfillmentRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));
    // The correct functions should have been called on the arbitrum contracts.
    expect(l1ERC20Gateway.outboundTransfer).to.have.been.calledOnce; // One token transfer over the canonical bridge.
    expect(l1ERC20Gateway.outboundTransfer).to.have.been.calledWith(
      dai.address,
      mockSpoke.address,
      tokensSendToL2,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      "0x"
    );
    expect(l1Inbox.createRetryableTicket).to.have.been.calledOnce; // only 1 L1->L2 message sent.
    expect(l1Inbox.createRetryableTicket).to.have.been.calledWith(
      mockSpoke.address,
      0,
      consts.sampleL2MaxSubmissionCost,
      owner.address,
      owner.address,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      mockSpoke.interface.encodeFunctionData("initializeRelayerRefund", [consts.mockDestinationDistributionRoot, consts.mockSlowRelayFulfillmentRoot])
    );
  });
});
