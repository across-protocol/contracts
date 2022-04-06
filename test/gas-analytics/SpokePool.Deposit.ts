import { toBNWei, SignerWithAddress, Contract, ethers, seedWallet, toBN } from "../utils";
import { constructDepositParams, sendDeposit, warmSpokePool } from "./utils";
import * as constants from "../constants";
import { spokePoolFixture } from "../fixtures/SpokePool.Fixture";

require("dotenv").config();

let spokePool: Contract, weth: Contract, erc20: Contract;
let depositor: SignerWithAddress;

// Constants caller can tune to modify gas tests.
const DEPOSIT_COUNT = 10;
const DEPOSIT_AMOUNT = toBNWei("10");

describe("Gas Analytics: SpokePool Deposits", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [depositor] = await ethers.getSigners();
    ({ spokePool, weth, erc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for the depositor.
    // Note: Mint more than needed for this test to simulate production, otherwise reported gas costs
    // will be better because a storage slot is deleted.
    const totalDepositAmount = DEPOSIT_AMOUNT.mul(DEPOSIT_COUNT);
    await seedWallet(depositor, [erc20], weth, totalDepositAmount.mul(toBN(100)));

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, constants.maxUint256);
    await weth.connect(depositor).approve(spokePool.address, constants.maxUint256);

    // "warm" contract with 1 initial deposit to better estimate steady state gas costs of contract.
    await warmSpokePool(spokePool, depositor, depositor, erc20.address, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0);
    await warmSpokePool(spokePool, depositor, depositor, weth.address, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0);
  });

  describe(`ERC20 Deposits`, function () {
    it("1 Deposit", async function () {
      const txn = await sendDeposit(spokePool, depositor, erc20.address, DEPOSIT_AMOUNT);

      const receipt = await txn.wait();
      console.log(`deposit-gasUsed: ${receipt.gasUsed}`);
    });
    it(`${DEPOSIT_COUNT} deposits`, async function () {
      const txns = [];
      for (let i = 0; i < DEPOSIT_COUNT; i++) {
        txns.push(await sendDeposit(spokePool, depositor, erc20.address, DEPOSIT_AMOUNT));
      }

      // Compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) deposit-gasUsed: ${gasUsed.div(DEPOSIT_COUNT)}`);
    });

    it(`${DEPOSIT_COUNT} deposits using multicall`, async function () {
      const currentSpokePoolTime = await spokePool.getCurrentTime();

      const multicallData = Array(DEPOSIT_COUNT).fill(
        spokePool.interface.encodeFunctionData(
          "deposit",
          constructDepositParams(depositor.address, erc20.address, currentSpokePoolTime, DEPOSIT_AMOUNT)
        )
      );

      const receipt = await (await spokePool.connect(depositor).multicall(multicallData)).wait();
      console.log(`(average) deposit-gasUsed: ${receipt.gasUsed.div(DEPOSIT_COUNT)}`);
    });
  });
  describe(`WETH Deposits`, function () {
    it("1 ETH Deposit", async function () {
      const currentSpokePoolTime = await spokePool.getCurrentTime();

      const txn = await spokePool
        .connect(depositor)
        .deposit(...constructDepositParams(depositor.address, weth.address, currentSpokePoolTime, DEPOSIT_AMOUNT), {
          value: DEPOSIT_AMOUNT,
        });

      const receipt = await txn.wait();
      console.log(`deposit-gasUsed: ${receipt.gasUsed}`);
    });
  });
});
