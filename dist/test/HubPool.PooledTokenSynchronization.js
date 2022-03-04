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
describe("HubPool Pooled Token Synchronization", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_1.seedWallet)(dataWorker, [], weth, consts.amountToLp);
    await (0, utils_1.seedWallet)(liquidityProvider, [], weth, consts.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });
  it("Sync updates counters correctly through the lifecycle of a relay", async function () {
    // Values start as expected.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    // Calling sync at this point should not change the counters.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    // Execute a relayer refund. Check counters move accordingly.
    const { tokensSendToL2, realizedLpFees, leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      weth.address
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    // Bond being paid in should not impact liquid reserves.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    // Counters should move once the root bundle is executed.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      tokensSendToL2.add(realizedLpFees)
    );
    // Calling sync again does nothing.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      tokensSendToL2.add(realizedLpFees)
    );
    // Next, move time forward past the end of the 1 week L2 liveness, say 10 days. At this point all fees should also
    // have been attributed to the LPs. The Exchange rate should update to (1000+10)/1000=1.01. Sync should still not
    // change anything as no tokens have been sent directly to the contracts (yet).
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      tokensSendToL2.add(realizedLpFees)
    );
    // Now, mimic the conclusion of the of the L2 -> l1 token transfer which pays back the LPs. The bundle of relays
    // executed on L2 constituted a relayer repayment of 100 tokens. The LPs should now have received 100 tokens + the
    // realizedLp fees of 10 tokens. i.e there should be a transfer of 110 tokens from L2->L1. This is represented by
    // simply send the tokens to the hubPool. The sync method should correctly attribute this to the trackers
    await weth.connect(dataWorker).transfer(hubPool.address, tokensSendToL2.add(realizedLpFees));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    // Liquid reserves should now be the sum of original LPed amount + the realized fees. This should equal the amount
    // LPed minus the amount sent to L2, plus the amount sent back to L1 (they are equivalent).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves)
      .to.equal(consts.amountToLp.add(realizedLpFees))
      .to.equal(consts.amountToLp.sub(tokensSendToL2).add(tokensSendToL2).add(realizedLpFees));
    // All funds have returned to L1. As a result, the utilizedReserves should now be 0.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal((0, utils_1.toBNWei)(0));
    // Finally, the exchangeRate should not have changed, even though the token balance of the contract has changed.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
  });
  it("Token balance trackers sync correctly when tokens are dropped onto the contract", async function () {
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    const amountToSend = (0, utils_1.toBNWei)(10);
    await weth.connect(dataWorker).transfer(hubPool.address, amountToSend);
    // The token balances should now sync correctly. Liquid reserves should capture the new funds sent to the hubPool
    // and the utilizedReserves should be negative in size equal to the tokens dropped onto the contract.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.add(amountToSend)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      (0, utils_1.toBNWei)(-10)
    );
    // Importantly the exchange rate should not have changed.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
  });
  it("Liquidity utilization correctly tracks the utilization of liquidity", async function () {
    // Liquidity utilization starts off at 0 before any actions are done.
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    // Execute a relayer refund. Check counters move accordingly.
    const { tokensSendToL2, realizedLpFees, leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      weth.address
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
    // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      (0, utils_1.toBNWei)(0.10891089108910891)
    );
    // Advance time such that all LP fees have been paid out. Liquidity utilization should not have changed.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      (0, utils_1.toBNWei)(0.10891089108910891)
    );
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      tokensSendToL2.add(realizedLpFees)
    );
    // Now say that the LPs remove half their liquidity(withdraw 500 LP tokens). Removing half the LP tokens should send
    // back 500*1.01=505 tokens to the liquidity provider. Validate that the expected tokens move.
    const amountToWithdraw = (0, utils_1.toBNWei)(500);
    const tokensReturnedForWithdrawnLpTokens = amountToWithdraw
      .mul((0, utils_1.toBNWei)(1.01))
      .div((0, utils_1.toBNWei)(1));
    await (0, utils_1.expect)(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, (0, utils_1.toBNWei)(500), false)
    ).to.changeTokenBalance(weth, liquidityProvider, tokensReturnedForWithdrawnLpTokens);
    // Pool trackers should update accordingly.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    // Liquid reserves should now be the original LPed amount, minus that sent to l2, minus the fees removed from the
    // pool due to redeeming the LP tokens as 1000-100-500*1.01=395. Utilized reserves should not change.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2).sub(tokensReturnedForWithdrawnLpTokens)
    );
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(
      tokensSendToL2.add(realizedLpFees)
    );
    // The associated liquidity utilization should be utilizedReserves / (liquidReserves + utilizedReserves) as
    // (110) / (395 + 110) = 0.217821782178217821
    (0, utils_1.expect)((await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).toString()).to.equal(
      (0, utils_1.toBNWei)("0.217821782178217821")
    );
    // Now, mint tokens to mimic the finalization of the relay. The utilization should go back to 0.
    await weth.connect(dataWorker).transfer(hubPool.address, tokensSendToL2.add(realizedLpFees));
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
  });
  it("Liquidity utilization is always floored at 0, even if tokens are dropped onto the contract", async function () {
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await weth.connect(dataWorker).transfer(hubPool.address, (0, utils_1.toWei)(500));
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    // Seeing tokens were gifted onto the contract in size greater than the actual utilized reserves utilized reserves is
    // floored to 0. The utilization equation is therefore relayedAmount / liquidReserves. For a relay of 100 units,
    // the utilization should therefore be 100 / 1500 = 0.06666666666666667.
    (0, utils_1.expect)(
      (await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, (0, utils_1.toBNWei)(100))).toString()
    ).to.equal("66666666666666666");
    // A larger relay of 600 should be 600/ 1500 = 0.4
    (0, utils_1.expect)(
      await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, (0, utils_1.toBNWei)(600))
    ).to.equal((0, utils_1.toBNWei)(0.4));
  });
  it("Liquidity utilization post relay correctly computes expected utilization for a given relay size", async function () {
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address))
      .to.equal(await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, 0))
      .to.equal(0);
    // A relay of 10 Tokens should result in a liquidity utilization of 100 / (900 + 100) = 0.1.
    (0, utils_1.expect)(
      await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, (0, utils_1.toBNWei)(100))
    ).to.equal((0, utils_1.toBNWei)(0.1));
    // Execute a relay refund bundle to increase the liquidity utilization.
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
    // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      (0, utils_1.toBNWei)(0.10891089108910891)
    );
  });
  it("High liquidity utilization blocks LPs from withdrawing", async function () {
    // Execute a relayer refund bundle. Set the scalingSize to 5. This will use 500 ETH from the hubPool.
    const { leafs, tree } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address, 5);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    // Liquidity utilization should now be (550) / (500 + 550) = 0.523809523809523809. I.e utilization is over 50%.
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      "523809523809523809"
    );
    // Now, trying to withdraw 51% of the liquidity in an LP position should revert.
    await (0, utils_1.expect)(
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, (0, utils_1.toBNWei)(501), false)
    ).to.be.reverted;
    // Can remove exactly at the 50% mark, removing all free liquidity.
    const currentExchangeRate = await hubPool.callStatic.exchangeRateCurrent(weth.address);
    (0, utils_1.expect)(currentExchangeRate).to.equal((0, utils_1.toWei)(1.05));
    // Calculate the absolute maximum LP tokens that can be redeemed as the 500 tokens that we know are liquid in the
    // contract (we used 500 in the relayer refund) divided by the exchange rate. Add one wei as this operation will
    // round down. We can check that this redemption amount will return exactly 500 tokens.
    const maxRedeemableLpTokens = (0, utils_1.toBNWei)(500)
      .mul((0, utils_1.toBNWei)(1))
      .div(currentExchangeRate)
      .add(1);
    await (0, utils_1.expect)(
      () => hubPool.connect(liquidityProvider).removeLiquidity(weth.address, maxRedeemableLpTokens, false) // redeem
    ).to.changeTokenBalance(weth, liquidityProvider, (0, utils_1.toBNWei)(500)); // should send back exactly 500 tokens.
    // After this, the liquidity utilization should be exactly 100% with 0 tokens left in the contract.
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      (0, utils_1.toBNWei)(1)
    );
    (0, utils_1.expect)(await weth.balanceOf(hubPool.address)).to.equal(0);
    // Trying to remove even 1 wei should fail.
    await (0, utils_1.expect)(hubPool.connect(liquidityProvider).removeLiquidity(weth.address, 1, false)).to.be
      .reverted;
  });
  it("Redeeming all LP tokens, after accruing fees, is handled correctly", async function () {
    const { leafs, tree, tokensSendToL2, realizedLpFees } = await (0, MerkleLib_utils_1.constructSingleChainTree)(
      weth.address
    );
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    // Send back to L1 the tokensSendToL2 + realizedLpFees, i.e to mimic the finalization of the relay.
    await weth.connect(dataWorker).transfer(hubPool.address, tokensSendToL2.add(realizedLpFees));
    // Exchange rate should be 1.01 (accumulated 10 WETH on 1000 WETH worth of liquidity). Utilization should be 0.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
    (0, utils_1.expect)(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(
      (0, utils_1.toBNWei)(0)
    );
    // Now, trying to all liquidity.
    await hubPool.connect(liquidityProvider).removeLiquidity(weth.address, consts.amountToLp, false);
    // Exchange rate is now set to 1.0 as all fees have been withdrawn.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    const pooledTokenInfoPreExecution = await hubPool.pooledTokens(weth.address);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.liquidReserves).to.equal(0);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.utilizedReserves).to.equal(0);
    (0, utils_1.expect)(pooledTokenInfoPreExecution.undistributedLpFees).to.equal(0);
    // Now, mint LP tokens again. The exchange rate should be re-set to 0 and have no memory of the previous deposits.
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    // Exchange rate should be 1.0 as all fees have been withdrawn.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1));
    // Going through a full refund lifecycle does returns to where we were before, with no memory of previous fees.
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    // Exchange rate should be 1.01, with 1% accumulated on the back of refunds with no memory of the previous fees.
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
  });
});
