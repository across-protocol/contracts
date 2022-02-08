import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, toBNWei, seedWallet, toWei } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { constructSimple1ChainTree } from "./MerkleLib.utils";

let hubPool: Contract, weth: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Pooled Token Synchronization", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });

  it("Sync updates counters correctly through the lifecycle of a relay", async function () {
    // Values start as expected.
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1));

    // Calling sync at this point should not change the counters.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1));

    // Execute a relayer refund. Check counters move accordingly.
    const { tokensSendToL2, realizedLpFees, leafs, tree } = await constructSimple1ChainTree(weth);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp.sub(tokensSendToL2));
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));

    // Calling sync again does nothing.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp.sub(tokensSendToL2));
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));

    // Next, move time forward past the end of the 1 week L2 liveness, say 10 days. At this point all fees should also
    // have been attributed to the LPs. The Exchange rate should update to (1000+10)/1000=1.01. Sync should still not
    // change anything as no tokens have been sent directly to the contracts (yet).
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1.01));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp.sub(tokensSendToL2));
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));

    // Now, mimic the conclusion of the of the L2 -> l1 token transfer which pays back the LPs. The bundle of relays
    // executed on L2 constituted a relayer repayment of 100 tokens. The LPs should now have received 100 tokens + the
    // realizedLp fees of 10 tokens. i.e there should be a transfer of 110 tokens from L2->L1. This is represented by
    // simply send the tokens to the hubPool. The sync method should correctly attribute this to the trackers
    const l2ToL1Amount = toBNWei(110);
    await weth.connect(dataWorker).transfer(hubPool.address, l2ToL1Amount);

    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).

    // Liquid reserves should now be the sum of original LPed amount + the realized fees. This should equal the amount
    // LPed minus the amount sent to L2, plus the amount sent back to L1 (they are equivalent).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves)
      .to.equal(consts.amountToLp.add(realizedLpFees))
      .to.equal(consts.amountToLp.sub(tokensSendToL2).add(l2ToL1Amount));

    // All funds have returned to L1. As a result, the utilizedReserves should now be 0.
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(toBNWei(0));

    // Finally, the exchangeRate should not have changed, even though the token balance of the contract has changed.
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1.01));
  });

  it("Token balance trackers sync correctly when tokens are dropped onto the contract", async function () {
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp);
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(0);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1));

    const amountToSend = toBNWei(10);
    await weth.connect(dataWorker).transfer(hubPool.address, amountToSend);

    // The token balances should now sync correctly. Liquid reserves should capture the new funds sent to the hubPool
    // and the utilizedReserves should be negative in size equal to the tokens dropped onto the contract.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp.add(amountToSend));
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(toBNWei(-10));
    // Importantly the exchange rate should not have changed.
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1));
  });
  it("Liquidity utilization correctly tracks the utilization of liquidity", async function () {
    // Liquidity utilization starts off at 0 before any actions are done.
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    // Execute a relayer refund. Check counters move accordingly.
    const { tokensSendToL2, realizedLpFees, leafs, tree } = await constructSimple1ChainTree(weth);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot);

    // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
    // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(toBNWei(0.10891089108910891));

    // Advance time such that all LP fees have been paid out. Liquidity utilization should not have changed.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1.01));
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(toBNWei(0.10891089108910891));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(consts.amountToLp.sub(tokensSendToL2));
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));

    // Now say that the LPs remove half their liquidity(withdraw 500 LP tokens). Removing half the LP tokens should send
    // back 500*1.01=505 tokens to the liquidity provider. Validate that the expected tokens move.
    const amountToWithdraw = toBNWei(500);
    const tokensReturnedForWithdrawnLpTokens = amountToWithdraw.mul(toBNWei(1.01)).div(toBNWei(1));
    await expect(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, toBNWei(500), false)
    ).to.changeTokenBalance(weth, liquidityProvider, tokensReturnedForWithdrawnLpTokens);

    // Pool trackers should update accordingly.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync (calls sync internally).
    // Liquid reserves should now be the original LPed amount, minus that sent to l2, minus the fees removed from the
    // pool due to redeeming the LP tokens as 1000-100-500*1.01=395. Utilized reserves should not change.
    expect((await hubPool.pooledTokens(weth.address)).liquidReserves).to.equal(
      consts.amountToLp.sub(tokensSendToL2).sub(tokensReturnedForWithdrawnLpTokens)
    );
    expect((await hubPool.pooledTokens(weth.address)).utilizedReserves).to.equal(tokensSendToL2.add(realizedLpFees));
    // The associated liquidity utilization should be utilizedReserves / (liquidReserves + utilizedReserves) as
    // (110) / (395 + 110) = 0.217821782178217821
    expect((await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).toString()).to.equal(
      toBNWei("0.217821782178217821")
    );
    // Now, mint tokens to mimic the finalization of the relay. The utilization should go back to 0.
    await weth.connect(dataWorker).transfer(hubPool.address, tokensSendToL2.add(realizedLpFees));
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
  });
  it("Liquidity utilization is always floored at 0, even if tokens are dropped onto the contract", async function () {
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await weth.connect(dataWorker).transfer(hubPool.address, toWei(500));
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);

    // Seeing tokens were gifted onto the contract in size greater than the actual utilized reserves utilized reserves is
    // floored to 0. The utilization equation is therefore relayedAmount / liquidReserves. For a relay of 100 units,
    // the utilization should therefore be 100 / 1500 = 0.06666666666666667.
    expect((await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, toBNWei(100))).toString()).to.equal(
      "66666666666666666"
    );

    // A larger relay of 600 should be 600/ 1500 = 0.4
    expect(await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, toBNWei(600))).to.equal(toBNWei(0.4));
  });
  it("Liquidity utilization post relay correctly computes expected utilization for a given relay size", async function () {
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address))
      .to.equal(await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, 0))
      .to.equal(0);

    // A relay of 10 Tokens should result in a liquidity utilization of 100 / (900 + 100) = 0.1.
    expect(await hubPool.callStatic.liquidityUtilizationPostRelay(weth.address, toBNWei(100))).to.equal(toBNWei(0.1));

    // Execute a relay refund bundle to increase the liquidity utilization.
    const { leafs, tree } = await constructSimple1ChainTree(weth);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot);

    // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(0);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
    // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(toBNWei(0.10891089108910891));
  });
  it("High liquidity utilization blocks LPs from withdrawing", async function () {
    // Execute a relayer refund bundle. Set the scalingSize to 5. This will use 500 ETH from the hubPool.
    const { leafs, tree } = await constructSimple1ChainTree(weth, 5);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Most to accumulate all fees.

    // Liquidity utilization should now be (550) / (500 + 550) = 0.523809523809523809. I.e utilization is over 50%.
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal("523809523809523809");

    // Now, trying to withdraw 51% of the liquidity in an LP position should revert.
    await expect(hubPool.connect(liquidityProvider).removeLiquidity(weth.address, toBNWei(501), false)).to.be.reverted;

    // Can remove exactly at the 50% mark, removing all free liquidity.
    const currentExchangeRate = await hubPool.callStatic.exchangeRateCurrent(weth.address);
    expect(currentExchangeRate).to.equal(toWei(1.05));
    // Calculate the absolute maximum LP tokens that can be redeemed as the 500 tokens that we know are liquid in the
    // contract (we used 500 in the relayer refund) divided by the exchange rate. Add one wei as this operation will
    // round down. We can check that this redemption amount will return exactly 500 tokens.
    const maxRedeemableLpTokens = toBNWei(500).mul(toBNWei(1)).div(currentExchangeRate).add(1);
    await expect(
      () => hubPool.connect(liquidityProvider).removeLiquidity(weth.address, maxRedeemableLpTokens, false) // redeem
    ).to.changeTokenBalance(weth, liquidityProvider, toBNWei(500)); // should send back exactly 500 tokens.

    // After this, the liquidity utilization should be exactly 100% with 0 tokens left in the contract.
    expect(await hubPool.callStatic.liquidityUtilizationCurrent(weth.address)).to.equal(toBNWei(1));
    expect(await weth.balanceOf(hubPool.address)).to.equal(0);

    // Trying to remove even 1 wei should fail.
    await expect(hubPool.connect(liquidityProvider).removeLiquidity(weth.address, 1, false)).to.be.reverted;
  });
});
