import { toBNWei, SignerWithAddress, Contract, ethers, seedWallet, toBN } from "../utils";
import { constructRelayParams, warmSpokePool, sendRelay } from "./utils";
import * as constants from "../constants";
import { spokePoolFixture, enableRoutes } from "../fixtures/SpokePool.Fixture";

require("dotenv").config();

let spokePool: Contract, weth: Contract, erc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress;

// Constants caller can tune to modify gas tests.
const RELAY_COUNT = 10;
const RELAY_AMOUNT = toBNWei("10");

describe("Gas Analytics: SpokePool Relays", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [depositor, recipient] = await ethers.getSigners();
    ({ spokePool, weth, erc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for the relayer.
    // Note: Mint more than needed for this test to simulate production, otherwise reported gas costs
    // will be better because a storage slot is deleted.
    // Note 2: For the same reason as above, seed recipient address with wallet balance to better simulate production.
    const totalRelayAmount = RELAY_AMOUNT.mul(RELAY_COUNT);
    await seedWallet(depositor, [erc20], weth, totalRelayAmount.mul(toBN(10)));
    await seedWallet(recipient, [erc20], weth, totalRelayAmount.mul(toBN(10)));

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, constants.maxUint256);
    await weth.connect(depositor).approve(spokePool.address, constants.maxUint256);

    // "warm" contract with 1 initial deposit and relay to better estimate steady state gas costs of contract.
    await warmSpokePool(spokePool, depositor, depositor, erc20.address, RELAY_AMOUNT, RELAY_AMOUNT, 0);
    await warmSpokePool(spokePool, depositor, depositor, weth.address, RELAY_AMOUNT, RELAY_AMOUNT, 0);
  });

  describe(`ERC20 Relays`, function () {
    it("1 Relay", async function () {
      const txn = await sendRelay(
        spokePool,
        depositor,
        depositor.address,
        recipient.address,
        erc20.address,
        RELAY_AMOUNT,
        0
      );

      const receipt = await txn.wait();
      console.log(`fillRelay-gasUsed: ${receipt.gasUsed}`);
    });
    it(`${RELAY_COUNT} Relays`, async function () {
      const txns = [];
      for (let i = 0; i < RELAY_COUNT; i++) {
        txns.push(
          await sendRelay(spokePool, depositor, depositor.address, recipient.address, erc20.address, RELAY_AMOUNT, i)
        );
      }

      // Compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) fillRelay-gasUsed: ${gasUsed.div(RELAY_COUNT)}`);
    });

    it(`${RELAY_COUNT} relays using multicall`, async function () {
      const multicallData = [...Array(RELAY_COUNT).keys()].map((i) => {
        return spokePool.interface.encodeFunctionData(
          "fillRelay",
          constructRelayParams(depositor.address, recipient.address, erc20.address, i, RELAY_AMOUNT)
        );
      });

      const receipt = await (await spokePool.connect(depositor).multicall(multicallData)).wait();
      console.log(`(average) fillRelay-gasUsed: ${receipt.gasUsed.div(RELAY_COUNT)}`);
    });
  });
  describe(`WETH Relays`, function () {
    it("1 Relay", async function () {
      const txn = await sendRelay(
        spokePool,
        depositor,
        depositor.address,
        recipient.address,
        weth.address,
        RELAY_AMOUNT,
        0
      );
      const receipt = await txn.wait();
      console.log(`fillRelay-gasUsed: ${receipt.gasUsed}`);
    });
  });
});
