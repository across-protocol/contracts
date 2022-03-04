"use strict";
var __createBinding =
  (this && this.__createBinding) ||
  (Object.create
    ? function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        Object.defineProperty(o, k2, {
          enumerable: true,
          get: function () {
            return m[k];
          },
        });
      }
    : function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        o[k2] = m[k];
      });
var __setModuleDefault =
  (this && this.__setModuleDefault) ||
  (Object.create
    ? function (o, v) {
        Object.defineProperty(o, "default", { enumerable: true, value: v });
      }
    : function (o, v) {
        o["default"] = v;
      });
var __importStar =
  (this && this.__importStar) ||
  function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null)
      for (var k in mod)
        if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
  };
Object.defineProperty(exports, "__esModule", { value: true });
const consts = __importStar(require("../constants"));
const utils_1 = require("../utils");
const utils_2 = require("../utils");
const HubPool_Fixture_1 = require("../fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("../MerkleLib.utils");
let hubPool, arbitrumAdapter, mockAdapter, weth, dai, timer, mockSpoke;
let l2Weth, l2Dai;
let owner, dataWorker, liquidityProvider;
let l1ERC20Gateway, l1Inbox;
const arbitrumChainId = 42161;
let l1ChainId;
describe("Arbitrum Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer, mockAdapter } = await (0,
    HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_2.seedWallet)(dataWorker, [dai], weth, consts.amountToLp);
    await (0, utils_2.seedWallet)(liquidityProvider, [dai], weth, consts.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, consts.amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    l1Inbox = await (0, utils_1.createFake)("Inbox");
    l1ERC20Gateway = await (0, utils_1.createFake)("TokenGateway");
    l1ChainId = Number(await utils_1.hre.getChainId());
    arbitrumAdapter = await (
      await (0, utils_2.getContractFactory)("Arbitrum_Adapter", owner)
    ).deploy(l1Inbox.address, l1ERC20Gateway.address);
    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: (0, utils_1.toWei)("1") });
    await hubPool.setCrossChainContracts(arbitrumChainId, arbitrumAdapter.address, mockSpoke.address);
    await hubPool.whitelistRoute(arbitrumChainId, l1ChainId, l2Weth, weth.address);
    await hubPool.whitelistRoute(arbitrumChainId, l1ChainId, l2Dai, dai.address);
    await hubPool.setCrossChainContracts(l1ChainId, mockAdapter.address, mockSpoke.address);
    await hubPool.whitelistRoute(l1ChainId, arbitrumChainId, dai.address, l2Dai);
    await hubPool.whitelistRoute(l1ChainId, arbitrumChainId, weth.address, l2Weth);
  });
  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = (0, utils_2.randomAddress)();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    (0, utils_1.expect)(await hubPool.relaySpokePoolAdminFunction(arbitrumChainId, functionCallData))
      .to.emit(arbitrumAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    (0, utils_1.expect)(l1Inbox.createRetryableTicket).to.have.been.calledThrice;
    (0, utils_1.expect)(l1Inbox.createRetryableTicket).to.have.been.calledWith(
      mockSpoke.address,
      0,
      consts.sampleL2MaxSubmissionCost,
      owner.address,
      owner.address,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      functionCallData
    );
  });
  it("Correctly calls appropriate arbitrum bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leafs, tree, tokensSendToL2 } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      dai.address,
      1,
      arbitrumChainId
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // The correct functions should have been called on the arbitrum contracts.
    (0, utils_1.expect)(l1ERC20Gateway.outboundTransfer).to.have.been.calledOnce; // One token transfer over the canonical bridge.
    (0, utils_1.expect)(l1ERC20Gateway.outboundTransfer).to.have.been.calledWith(
      dai.address,
      mockSpoke.address,
      tokensSendToL2,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      "0x"
    );
    (0, utils_1.expect)(l1Inbox.createRetryableTicket).to.have.been.calledThrice; // only 1 L1->L2 message sent. Note that the two
    // whitelist transactions already sent two messages.
    (0, utils_1.expect)(l1Inbox.createRetryableTicket).to.have.been.calledWith(
      mockSpoke.address,
      0,
      consts.sampleL2MaxSubmissionCost,
      owner.address,
      owner.address,
      consts.sampleL2Gas,
      consts.sampleL2GasPrice,
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
      ])
    );
  });
});
