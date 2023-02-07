import { proposeRootBundle } from "../BondToken.e2e";
import { bondAmount, maxUint256 } from "../constants";
import { Contract, ethers, seedWallet, SignerWithAddress, toBN } from "../utils";
import { bondTokenFixture } from "../fixtures/BondToken.Fixture";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";

require("dotenv").config();

let bondToken: Contract, hubPool: Contract;
let owner: SignerWithAddress, proposer: SignerWithAddress, disputer: SignerWithAddress;

describe("Gas Analytics: BondToken Transfers", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    let collateralWhitelist: Contract;

    [owner, proposer, disputer] = await ethers.getSigners();
    ({ hubPool, collateralWhitelist } = await hubPoolFixture());
    ({ bondToken } = await bondTokenFixture(hubPool));
    await collateralWhitelist.addToWhitelist(bondToken.address);

    // Configure HubPool bond. BondTokenFixture() pre-registers bondToken as accepted OO collateral.
    await hubPool.connect(owner).setBond(bondToken.address, bondAmount);

    // Pre-approve the proposer.
    await bondToken.connect(owner).setProposer(proposer.address, true);
    await bondToken.proposers(proposer.address);

    // Handle token approvals.
    for (const signer of [proposer, disputer]) {
      await seedWallet(signer, [], bondToken, bondAmount.mul(toBN(5)));
      await bondToken.connect(signer).approve(hubPool.address, maxUint256);
    }
  });

  describe(`ERC20 Transfers`, function () {
    it("Proposer transfers to HubPool", async function () {
      for (const pass of [1, 2]) {
        const txn = await bondToken.connect(proposer).transferFrom(proposer.address, hubPool.address, bondAmount);
        const receipt = await txn.wait();
        console.log(`transferFrom() gasUsed on pass ${pass}: ${receipt.gasUsed}`);
      }
    });

    it("Proposer transfers to Disputer", async function () {
      const txn = await bondToken.connect(proposer).transferFrom(proposer.address, disputer.address, bondAmount);
      const receipt = await txn.wait();
      console.log(`transferFrom() gasUsed: ${receipt.gasUsed}`);
    });

    it("Disputer transfers to HubPool", async function () {
      for (const pass of [1, 2]) {
        const txn = await bondToken.connect(disputer).transferFrom(disputer.address, hubPool.address, bondAmount);
        const receipt = await txn.wait();
        console.log(`transferFrom() gasUsed on pass ${pass}: ${receipt.gasUsed}`);
      }
    });
  });
});
