import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";

import { SignerWithAddress, toBNWei, seedWallet } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { buildPoolRebalanceTree, buildPoolRebalanceLeafs } from "./MerkleLib.utils";

let hubPool: Contract, mockAdapter: Contract, weth: Contract, mockSpoke: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

async function constructSimpleTree() {
  const wethSendToL2 = toBNWei(100);
  const wethAttributeToLps = toBNWei(1);
  const leafs = buildPoolRebalanceLeafs(
    [consts.repaymentChainId], // repayment chain. In this test we only want to send one token to one chain.
    [weth], // l1Token. We will only be sending WETH and DAI to the associated repayment chain.
    [[wethAttributeToLps]], // bundleLpFees. Set to 1 ETH and 10 DAI respectively to attribute to the LPs.
    [[wethSendToL2]], // netSendAmounts. Set to 100 ETH and 1000 DAI as the amount to send from L1->L2.
    [[wethSendToL2]] // runningBalances. Set to 100 ETH and 1000 DAI.
  );
  const tree = await buildPoolRebalanceTree(leafs);

  return { wethSendToL2, wethAttributeToLps, leafs, tree };
}

describe.only("HubPool LP fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, mockAdapter, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });

  it("Fee tracking variables are correctly updated at the execution of a refund", async function () {
    // Before any execution happens liquidity trackers are set as expected.
    const pooledTokenInfoPreExecution = await hubPool.pooledTokens(weth.address);
    expect(pooledTokenInfoPreExecution.liquidReserves).to.eq(consts.amountToLp);
    expect(pooledTokenInfoPreExecution.utilizedReserves).to.eq(0);
    expect(pooledTokenInfoPreExecution.undistributedLpFees).to.eq(0);
    expect(pooledTokenInfoPreExecution.lastLpFeeUpdate).to.eq(await timer.getCurrentTime());
    expect(pooledTokenInfoPreExecution.isWeth).to.eq(true);

    const { wethSendToL2, wethAttributeToLps, leafs, tree } = await constructSimpleTree();
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);

    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    const pooledTokenInfoPostExecution = await hubPool.pooledTokens(weth.address);
    expect(pooledTokenInfoPostExecution.liquidReserves).to.eq(consts.amountToLp.sub(wethSendToL2));
    expect(pooledTokenInfoPostExecution.utilizedReserves).to.eq(wethSendToL2);
    expect(pooledTokenInfoPostExecution.undistributedLpFees).to.eq(wethAttributeToLps);
    // expect(pooledTokenInfoPostExecution.lockedBonds).to.eq(0);
    // expect(pooledTokenInfoPostExecution.lastLpFeeUpdate).to.eq(await timer.getCurrentTime());
  });
});
