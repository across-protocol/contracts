import { toBNWei, SignerWithAddress, Contract, ethers, seedWallet } from "../utils";
import { spokePoolFixture, getRelayHash, getFillRelayParams } from "../SpokePool.Fixture";

require("dotenv").config();

let spokePool: Contract, weth: Contract, erc20: Contract;
let depositor: SignerWithAddress;

// Constants caller can tune to modify gas tests.
const RELAY_COUNT = 10;
const RELAY_AMOUNT = toBNWei("10");

function constructRelayParams(relayTokenAddress: string, depositId: number) {
  const { relayData } = getRelayHash(depositor.address, depositor.address, depositId, 1, relayTokenAddress);
  return getFillRelayParams(relayData, RELAY_AMOUNT);
}
describe("Gas Analytics: SpokePool Relays", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [depositor] = await ethers.getSigners();
    ({ spokePool, weth, erc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for the relayer.
    const totalRelayAmount = RELAY_AMOUNT.mul(RELAY_COUNT);
    await seedWallet(depositor, [erc20], weth, totalRelayAmount);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, totalRelayAmount);
    await weth.connect(depositor).approve(spokePool.address, totalRelayAmount);
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
