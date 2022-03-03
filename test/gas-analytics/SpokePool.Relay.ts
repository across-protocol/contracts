import { toBNWei, SignerWithAddress, Contract, ethers, seedWallet, toBN } from "../utils";
import * as constants from "../constants";
import {
  spokePoolFixture,
  getRelayHash,
  getFillRelayParams,
  getDepositParams,
  enableRoutes,
} from "../fixtures/SpokePool.Fixture";

require("dotenv").config();

let spokePool: Contract, weth: Contract, erc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress;

// Constants caller can tune to modify gas tests.
const RELAY_COUNT = 10;
const RELAY_AMOUNT = toBNWei("10");

function constructRelayParams(relayTokenAddress: string, depositId: number) {
  const { relayData } = getRelayHash(depositor.address, recipient.address, depositId, 1, relayTokenAddress);
  return getFillRelayParams(relayData, RELAY_AMOUNT);
}
async function sendDeposit(tokenAddress: string) {
  const currentSpokePoolTime = await spokePool.getCurrentTime();
  return await spokePool
    .connect(depositor)
    .deposit(...getDepositParams(depositor.address, tokenAddress, RELAY_AMOUNT, 1, toBN("0"), currentSpokePoolTime));
}
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

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [
      {
        originToken: erc20.address,
        destinationChainId: 1,
      },
      {
        originToken: weth.address,
        destinationChainId: 1,
      },
    ]);

    // "warm" contract with 1 initial deposit and relay to better estimate steady state gas costs of contract.
    await sendDeposit(erc20.address);
    await sendDeposit(weth.address);
    await spokePool.connect(depositor).fillRelay(...constructRelayParams(erc20.address, 0));
    await spokePool.connect(depositor).fillRelay(...constructRelayParams(weth.address, 0));
  });

  describe(`ERC20 Relays`, function () {
    it("1 Relay", async function () {
      const txn = await spokePool.connect(depositor).fillRelay(...constructRelayParams(erc20.address, 0));

      const receipt = await txn.wait();
      console.log(`fillRelay-gasUsed: ${receipt.gasUsed}`);
    });
    it(`${RELAY_COUNT} Relays`, async function () {
      const txns = [];
      for (let i = 0; i < RELAY_COUNT; i++) {
        txns.push(await spokePool.connect(depositor).fillRelay(...constructRelayParams(erc20.address, i)));
      }

      // Compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) fillRelay-gasUsed: ${gasUsed.div(RELAY_COUNT)}`);
    });

    it(`${RELAY_COUNT} relays using multicall`, async function () {
      const multicallData = [...Array(RELAY_COUNT).keys()].map((i) => {
        return spokePool.interface.encodeFunctionData("fillRelay", constructRelayParams(erc20.address, i));
      });

      const receipt = await (await spokePool.connect(depositor).multicall(multicallData)).wait();
      console.log(`(average) fillRelay-gasUsed: ${receipt.gasUsed.div(RELAY_COUNT)}`);
    });
  });
  describe(`WETH Relays`, function () {
    it("1 Relay", async function () {
      const txn = await spokePool.connect(depositor).fillRelay(...constructRelayParams(weth.address, 0));

      const receipt = await txn.wait();
      console.log(`fillRelay-gasUsed: ${receipt.gasUsed}`);
    });
  });
});
