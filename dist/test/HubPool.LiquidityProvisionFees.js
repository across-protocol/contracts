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
const utils_1 = require("./utils");
const consts = __importStar(require("./constants"));
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("./MerkleLib.utils");
let hubPool, weth, timer;
let owner, dataWorker, liquidityProvider;
describe("HubPool Liquidity Provision Fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_1.seedWallet)(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await (0, utils_1.seedWallet)(liquidityProvider, [], weth, consts.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });
  it("Fee tracking variables are correctly updated at the execution of a refund", async function () {
    // Before any execution happens liquidity trackers are set as expected.
    const pooledTokenInfoPreExecution = await hubPool.pooledTokens(weth.address);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.liquidReserves).to.equal(consts.amountToLp);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.utilizedReserves).to.equal(0);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.undistributedLpFees).to.equal(0);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.lastLpFeeUpdate).to.equal(await timer.getCurrentTime());
    const { tokensSendToL2, realizedLpFees, leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      weth.address
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // Validate the post execution values have updated as expected. Liquid reserves should be the original LPed amount
    // minus the amount sent to L2. Utilized reserves should be the amount sent to L2 plus the attribute to LPs.
    // Undistributed LP fees should be attribute to LPs.
    const pooledTokenInfoPostExecution = await hubPool.pooledTokens(weth.address);
    (0, utils_1.expect)(pooledTokenInfoPostExecution.liquidReserves).to.equal(consts.amountToLp.sub(tokensSendToL2));
    // UtilizedReserves contains both the amount sent to L2 and the attributed LP fees.
    (0, utils_1.expect)(pooledTokenInfoPostExecution.utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));
    (0, utils_1.expect)(pooledTokenInfoPostExecution.undistributedLpFees).to.equal(realizedLpFees);
  });
  it("Exchange rate current correctly attributes fees over the smear period", async function () {
    // Fees are designed to be attributed over a period of time so they dont all arrive on L1 as soon as the bundle is
    // executed. We can validate that fees are correctly smeared by attributing some and then moving time forward and
    // validating that key variable shift as a function of time.
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address);
    // Exchange rate current before any fees are attributed execution should be 1.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    await hubPool.exchangeRateCurrent(weth.address);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // Exchange rate current right after the refund execution should be the amount deposited, grown by the 100 second
    // liveness period. Of the 10 ETH attributed to LPs, a total of 10*0.0000015*7201=0.108015 was attributed to LPs.
    // The exchange rate is therefore (1000+0.108015)/1000=1.000108015.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(
      (0, utils_1.toWei)(1.000108015)
    );
    // Validate the state variables are updated accordingly. In particular, undistributedLpFees should have decremented
    // by the amount allocated in the previous computation. This should be 10-0.108015=9.891985.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(
      (0, utils_1.toWei)(9.891985)
    );
    // Next, advance time 2 days. Compute the ETH attributed to LPs by multiplying the original amount allocated(10),
    // minus the previous computation amount(0.108) by the smear rate, by the duration to get the second periods
    // allocation of(10 - 0.108015) * 0.0000015 * (172800)=2.564002512.The exchange rate should be The sum of the
    // liquidity provided and the fees added in both periods as (1000+0.108015+2.564002512)/1000=1.002672017512.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 2 * 24 * 60 * 60);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(
      (0, utils_1.toWei)(1.002672017512)
    );
    // Again, we can validate that the undistributedLpFees have been updated accordingly. This should be set to the
    // original amount (10) minus the two sets of attributed LP fees as 10-0.108015-2.564002512=7.327982488.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(
      (0, utils_1.toWei)(7.327982488)
    );
    // Finally, advance time past the end of the smear period by moving forward 10 days. At this point all LP fees
    // should be attributed such that undistributedLpFees=0 and the exchange rate should simply be (1000+10)/1000=1.01.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);
  });
});
