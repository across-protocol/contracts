import { bondTokenFixture } from "./fixtures/BondToken.Fixture";
import { Contract, ethers, SignerWithAddress, expect } from "../utils/utils";

let bondToken: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("BondToken Admin functions", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    ({ bondToken } = await bondTokenFixture());
  });

  it("Owner can manage proposers", async function () {
    expect(await bondToken.proposers(owner.address)).to.be.false;

    expect(await bondToken.proposers(other.address)).to.be.false;
    expect(await bondToken.connect(owner).setProposer(other.address, true)).to.emit(bondToken, "ProposerModified");
    expect(await bondToken.proposers(other.address)).to.be.true;

    expect(await bondToken.proposers(other.address)).to.be.true;
    expect(await bondToken.connect(owner).setProposer(other.address, false)).to.emit(bondToken, "ProposerModified");
    expect(await bondToken.proposers(other.address)).to.be.false;
  });

  it("Non-owners can not manage proposers", async function () {
    expect(await bondToken.proposers(other.address)).to.be.false;
    for (const enabled of [true, false, true, false]) {
      await expect(bondToken.connect(other).setProposer(other.address, enabled)).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      expect(await bondToken.proposers(other.address)).to.be.false;
    }
  });
});
