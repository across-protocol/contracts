import { bondTokenFixture } from "./fixtures/BondToken.Fixture";
import { enableTokensForLP, hubPoolFixture } from "./fixtures/HubPool.Fixture";
import { Contract, ethers, seedWallet, SignerWithAddress, expect } from "../../utils/utils";
import { constructSimpleTree } from "./HubPool.ExecuteRootBundle";
import * as consts from "./constants";

let bondToken: Contract, hubPool: Contract, timer: Contract;
let owner: SignerWithAddress, dataworker: SignerWithAddress, other: SignerWithAddress, lp: SignerWithAddress;
let weth: Contract, dai: Contract;

export const proposeRootBundle = (hubPool: Contract, dataworker: SignerWithAddress) => {
  return hubPool
    .connect(dataworker)
    .proposeRootBundle(
      consts.mockBundleEvaluationBlockNumbers,
      consts.mockPoolRebalanceLeafCount,
      consts.mockPoolRebalanceRoot,
      consts.mockRelayerRefundRoot,
      consts.mockSlowRelayRoot
    );
};

describe("BondToken HubPool interactions", function () {
  beforeEach(async function () {
    let collateralWhitelist: Contract;

    [owner, dataworker, other, lp] = await ethers.getSigners();
    ({ hubPool, timer, collateralWhitelist, weth, dai } = await hubPoolFixture());
    ({ bondToken } = await bondTokenFixture(hubPool));
    await collateralWhitelist.addToWhitelist(bondToken.address);

    // Pre-seed the dataworker, because it always needs bondToken.
    await seedWallet(dataworker, [], bondToken, consts.bondAmount.mul(3));

    // Configure HubPool bond. BondTokenFixture() pre-registers bondToken as accepted OO collateral.
    await expect(hubPool.connect(owner).setBond(bondToken.address, consts.bondAmount))
      .to.emit(hubPool, "BondSet")
      .withArgs(bondToken.address, consts.bondAmount);

    // Set approvals with headroom.
    for (const signer of [dataworker, other]) {
      await bondToken.connect(signer).approve(hubPool.address, consts.totalBond.mul(5));
    }

    // Pre-approve the dataworker as a proposer.
    await expect(bondToken.connect(owner).setProposer(dataworker.address, true))
      .to.emit(bondToken, "ProposerModified")
      .withArgs(dataworker.address, true);
    expect(await bondToken.proposers(dataworker.address)).to.be.true;
  });

  it("Proposers can submit proposals to the HubPool", async function () {
    for (const allowedProposer of [false, true]) {
      const hubPoolBal = await bondToken.balanceOf(hubPool.address);
      const dataworkerBal = await bondToken.balanceOf(dataworker.address);

      // Update the permitted proposers mapping.
      await expect(bondToken.connect(owner).setProposer(dataworker.address, allowedProposer))
        .to.emit(bondToken, "ProposerModified")
        .withArgs(dataworker.address, allowedProposer);
      expect(await bondToken.proposers(dataworker.address)).to.equal(allowedProposer);

      if (!allowedProposer) {
        // Proposal unsuccessful; balances are unchanged.
        await expect(proposeRootBundle(hubPool, dataworker)).to.be.revertedWith("Transfer not permitted");
        expect((await bondToken.balanceOf(hubPool.address)).eq(hubPoolBal)).to.be.true;
        expect((await bondToken.balanceOf(dataworker.address)).eq(dataworkerBal)).to.be.true;
      } else {
        // Proposal successful; bondAmount is transferred from proposer to HubPool.
        await expect(proposeRootBundle(hubPool, dataworker)).to.emit(hubPool, "ProposeRootBundle");
        expect((await hubPool.rootBundleProposal()).proposer).to.equal(dataworker.address);
        expect(await bondToken.balanceOf(hubPool.address)).to.equal(hubPoolBal.add(consts.bondAmount));
        expect((await bondToken.balanceOf(dataworker.address)).eq(dataworkerBal.sub(consts.bondAmount))).to.be.true;
      }
    }
  });

  // This test is duplicated from test/HubPool.executeRootBundle(), but uses the custom bond token instead.
  it("Bonds from undisputed proposals can be refunded to the proposer", async function () {
    await seedWallet(lp, [dai], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(lp).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(lp).addLiquidity(weth.address, consts.amountToLp);
    await dai.connect(lp).approve(hubPool.address, consts.amountToLp.mul(10)); // LP with 10000 DAI.
    await hubPool.connect(lp).addLiquidity(dai.address, consts.amountToLp.mul(10));

    const { leaves, tree } = await constructSimpleTree();

    await hubPool
      .connect(dataworker)
      .proposeRootBundle([3117, 3118], 2, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);

    // Advance time so the request can be executed and execute both leaves.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataworker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Second execution sends bond back to data worker.
    const bondAmount = consts.bondAmount.add(consts.finalFee);
    expect(
      await hubPool.connect(dataworker).executeRootBundle(...Object.values(leaves[1]), tree.getHexProof(leaves[1]))
    ).to.changeTokenBalances(bondToken, [dataworker, hubPool], [bondAmount, bondAmount.mul(-1)]);
  });

  it("Proposers can self-dispute", async function () {
    await expect(proposeRootBundle(hubPool, dataworker)).to.emit(hubPool, "ProposeRootBundle");
    await expect(hubPool.connect(dataworker).disputeRootBundle()).to.emit(hubPool, "RootBundleDisputed");
  });

  /**
   * Disallowed proposers can self-dispute: the pending root bundle is deleted before ABT transferFrom() is invoked.
   */
  it("Disallowed proposers can self-dispute", async function () {
    await expect(proposeRootBundle(hubPool, dataworker)).to.emit(hubPool, "ProposeRootBundle");

    // Disallow the proposer (with a pending proposal).
    await expect(bondToken.connect(owner).setProposer(dataworker.address, false))
      .to.emit(bondToken, "ProposerModified")
      .withArgs(dataworker.address, false);

    // Proposer can still dispute.
    await expect(hubPool.connect(dataworker).disputeRootBundle())
      .to.emit(hubPool, "RootBundleDisputed")
      .withArgs(dataworker.address, await hubPool.getCurrentTime());
  });

  it("Non-proposers can conditionally send ABT to the HubPool", async function () {
    const bondAmount = consts.bondAmount;
    await seedWallet(other, [], bondToken, bondAmount.mul(3));

    expect((await bondToken.balanceOf(hubPool.address)).eq("0")).to.be.true;
    expect((await bondToken.balanceOf(other.address)).eq(bondAmount.mul(3))).to.be.true;

    // No pending proposal => transfer permitted.
    await expect(bondToken.connect(other).transfer(hubPool.address, bondAmount))
      .to.emit(bondToken, "Transfer")
      .withArgs(other.address, hubPool.address, bondAmount);
    expect((await bondToken.balanceOf(hubPool.address)).eq(bondAmount)).to.be.true;
    expect((await bondToken.balanceOf(other.address)).eq(bondAmount.mul(2))).to.be.true;

    // Pending proposal from a proposer => transfer permitted (emulates dispute).
    await expect(proposeRootBundle(hubPool, dataworker)).to.emit(hubPool, "ProposeRootBundle");
    expect((await bondToken.balanceOf(hubPool.address)).eq(bondAmount.mul(2))).to.be.true;
    await expect(bondToken.connect(other).transfer(hubPool.address, bondAmount))
      .to.emit(bondToken, "Transfer")
      .withArgs(other.address, hubPool.address, bondAmount);
    expect((await bondToken.balanceOf(hubPool.address)).eq(bondAmount.mul(3))).to.be.true;
    expect((await bondToken.balanceOf(other.address)).eq(bondAmount)).to.be.true;
  });

  it("Non-proposers can not submit proposals to the HubPool", async function () {
    await seedWallet(other, [], bondToken, consts.bondAmount);
    expect(await bondToken.balanceOf(other.address)).to.equal(consts.bondAmount);

    await expect(proposeRootBundle(hubPool, other)).to.be.revertedWith("Transfer not permitted");
  });

  it("Non-proposers can dispute root bundle proposals", async function () {
    await seedWallet(other, [], bondToken, consts.bondAmount);
    expect(await bondToken.balanceOf(other.address)).to.equal(consts.bondAmount);

    const hubPoolBal = await bondToken.balanceOf(hubPool.address);
    const dataworkerBal = await bondToken.balanceOf(dataworker.address);

    await expect(proposeRootBundle(hubPool, dataworker)).to.emit(hubPool, "ProposeRootBundle");
    expect((await hubPool.rootBundleProposal()).proposer).to.equal(dataworker.address);

    // Verify that other is not a proposer. HubPool is already an approved spender of other's bondToken.
    expect(await bondToken.proposers(other.address)).to.be.false;
    await expect(hubPool.connect(other).disputeRootBundle())
      .to.emit(hubPool, "RootBundleDisputed")
      .withArgs(other.address, await hubPool.getCurrentTime());
  });
});
