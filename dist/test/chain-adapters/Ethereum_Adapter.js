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
let hubPool, ethAdapter, weth, dai, mockSpoke, timer;
let owner, dataWorker, liquidityProvider, crossChainAdmin;
let l1ChainId;
describe("Ethereum Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, dai, hubPool, mockSpoke, timer, crossChainAdmin } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    l1ChainId = Number(await utils_1.hre.getChainId());
    await (0, utils_2.seedWallet)(dataWorker, [dai], weth, consts.amountToLp);
    await (0, utils_2.seedWallet)(liquidityProvider, [dai], weth, consts.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, consts.amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    ethAdapter = await (await (0, utils_2.getContractFactory)("Ethereum_Adapter", owner)).deploy();
    await hubPool.setCrossChainContracts(l1ChainId, ethAdapter.address, mockSpoke.address);
    await hubPool.whitelistRoute(l1ChainId, l1ChainId, weth.address, weth.address);
    await hubPool.whitelistRoute(l1ChainId, l1ChainId, dai.address, dai.address);
  });
  it("relayMessage calls spoke pool functions", async function () {
    (0, utils_1.expect)(await mockSpoke.crossDomainAdmin()).to.equal(crossChainAdmin.address);
    const newAdmin = (0, utils_1.randomAddress)();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    (0, utils_1.expect)(await hubPool.relaySpokePoolAdminFunction(l1ChainId, functionCallData))
      .to.emit(ethAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    (0, utils_1.expect)(await mockSpoke.crossDomainAdmin()).to.equal(newAdmin);
  });
  it("Correctly transfers tokens when executing pool rebalance", async function () {
    const { leafs, tree, tokensSendToL2 } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      dai.address,
      1,
      l1ChainId
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    (0, utils_1.expect)(await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0])))
      .to.emit(ethAdapter.attach(hubPool.address), "TokensRelayed")
      .withArgs(dai.address, dai.address, tokensSendToL2, mockSpoke.address);
  });
});
