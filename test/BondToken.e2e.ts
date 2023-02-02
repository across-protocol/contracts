import { bondTokenFixture } from "./fixtures/BondToken.Fixture";
import { hubPoolFixture } from "./fixtures/HubPool.Fixture";
import { Contract, ethers, seedWallet, SignerWithAddress, expect } from "./utils";
import * as consts from "./constants";

let bondToken: Contract, hubPool: Contract, timer: Contract;
let owner: SignerWithAddress, dataworker: SignerWithAddress, other: SignerWithAddress, lp: SignerWithAddress;
let weth: Contract, dai: Contract;

const proposeRootBundle = (hubPool: Contract, dataworker: SignerWithAddress) => {
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
