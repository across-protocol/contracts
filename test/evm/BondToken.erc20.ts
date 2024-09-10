import { bondTokenFixture } from "./fixtures/BondToken.Fixture";
import { Contract, ethers, seedWallet, SignerWithAddress, expect } from "../../utils/utils";
import { bondAmount } from "./constants";

const bondTokenName = "Across Bond Token";
const bondTokenSymbol = "ABT";
const bondTokenDecimals = 18;

let bondToken: Contract;
let owner: SignerWithAddress, other: SignerWithAddress, rando: SignerWithAddress;

// Most of this functionality falls through to the underlying WETH9 implementation.
// Testing here just demonstrates that ABT doesn't break anything.
describe("BondToken ERC20 functions", function () {
  beforeEach(async function () {
    [owner, other, rando] = await ethers.getSigners();
    ({ bondToken } = await bondTokenFixture());
  });

  it("Verify name, symbol and decimals", async function () {
    expect(await bondToken.name()).to.equal(bondTokenName);
    expect(await bondToken.symbol()).to.equal(bondTokenSymbol);
    expect(await bondToken.decimals()).to.equal(bondTokenDecimals);
  });

  it("Anyone can deposit into ABT", async function () {
    for (const signer of [owner, other]) {
      const abt = bondToken.connect(signer);
      await expect(abt.deposit({ value: bondAmount }))
        .to.emit(bondToken, "Deposit")
        .withArgs(signer.address, bondAmount);
      expect((await abt.balanceOf(signer.address)).eq(bondAmount)).to.be.true;
    }
  });

  it("ABT holders can withdraw", async function () {
    for (const signer of [owner, other, rando]) {
      await seedWallet(signer, [], bondToken, bondAmount);

      expect((await bondToken.balanceOf(signer.address)).eq(bondAmount)).to.be.true;
      await expect(bondToken.connect(signer).withdraw(bondAmount))
        .to.emit(bondToken, "Withdrawal")
        .withArgs(signer.address, bondAmount);
      expect((await bondToken.balanceOf(signer.address)).eq("0")).to.be.true;
    }
  });

  it("ABT holders can transfer", async function () {
    await seedWallet(other, [], bondToken, bondAmount);

    expect((await bondToken.balanceOf(other.address)).eq(bondAmount)).to.be.true;
    expect((await bondToken.balanceOf(rando.address)).eq("0")).to.be.true;
    await expect(bondToken.connect(other).transfer(rando.address, bondAmount))
      .to.emit(bondToken, "Transfer")
      .withArgs(other.address, rando.address, bondAmount);
    expect((await bondToken.balanceOf(other.address)).eq("0")).to.be.true;
    expect((await bondToken.balanceOf(rando.address)).eq(bondAmount)).to.be.true;
  });
});
