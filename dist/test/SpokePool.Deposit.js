"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const constants_1 = require("./constants");
let spokePool, weth, erc20, unwhitelistedErc20;
let depositor, recipient;
describe("SpokePool Depositor Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient] = await utils_1.ethers.getSigners();
    ({ weth, erc20, spokePool, unwhitelistedErc20 } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
    // mint some fresh tokens and deposit ETH for weth for the depositor.
    await (0, utils_1.seedWallet)(depositor, [erc20], weth, constants_1.amountToSeedWallets);
    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, constants_1.amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, constants_1.amountToDeposit);
    // Whitelist origin token => destination chain ID routes:
    await (0, SpokePool_Fixture_1.enableRoutes)(spokePool, [
      {
        originToken: erc20.address,
      },
      {
        originToken: weth.address,
      },
    ]);
  });
  it("Depositing ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();
    await (0, utils_1.expect)(
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            erc20.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          )
        )
    )
      .to.emit(spokePool, "FundsDeposited")
      .withArgs(
        constants_1.amountToDeposit,
        constants_1.destinationChainId,
        constants_1.depositRelayerFeePct,
        0,
        currentSpokePoolTime,
        erc20.address,
        recipient.address,
        depositor.address
      );
    // The collateral should have transferred from depositor to contract.
    (0, utils_1.expect)(await erc20.balanceOf(depositor.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToDeposit)
    );
    (0, utils_1.expect)(await erc20.balanceOf(spokePool.address)).to.equal(constants_1.amountToDeposit);
    // Deposit nonce should increment.
    (0, utils_1.expect)(await spokePool.numberOfDeposits()).to.equal(1);
  });
  it("Depositing ETH correctly wraps into WETH", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();
    // Fails if msg.value > 0 but doesn't match amount to deposit.
    await (0, utils_1.expect)(
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            weth.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          ),
          { value: 1 }
        )
    ).to.be.reverted;
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            weth.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          ),
          { value: constants_1.amountToDeposit }
        )
    ).to.changeEtherBalances(
      [depositor, weth],
      [constants_1.amountToDeposit.mul((0, utils_1.toBN)("-1")), constants_1.amountToDeposit]
    ); // ETH should transfer from depositor to WETH contract.
    // WETH balance for user should be same as start, but WETH balancein pool should increase.
    (0, utils_1.expect)(await weth.balanceOf(depositor.address)).to.equal(constants_1.amountToSeedWallets);
    (0, utils_1.expect)(await weth.balanceOf(spokePool.address)).to.equal(constants_1.amountToDeposit);
  });
  it("Depositing ETH with msg.value = 0 pulls WETH from depositor", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            weth.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          ),
          { value: 0 }
        )
    ).to.changeTokenBalances(
      weth,
      [depositor, spokePool],
      [constants_1.amountToDeposit.mul((0, utils_1.toBN)("-1")), constants_1.amountToDeposit]
    );
  });
  it("General failure cases", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();
    // Blocked if user hasn't approved token.
    await erc20.connect(depositor).approve(spokePool.address, 0);
    await (0, utils_1.expect)(
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            erc20.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          )
        )
    ).to.be.reverted;
    await erc20.connect(depositor).approve(spokePool.address, constants_1.amountToDeposit);
    // Can only deposit whitelisted token.
    await (0, utils_1.expect)(
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            unwhitelistedErc20.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          )
        )
    ).to.be.reverted;
    // Cannot deposit disabled route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, constants_1.destinationChainId, false);
    await (0, utils_1.expect)(
      spokePool
        .connect(depositor)
        .deposit(
          ...(0, SpokePool_Fixture_1.getDepositParams)(
            recipient.address,
            erc20.address,
            constants_1.amountToDeposit,
            constants_1.destinationChainId,
            constants_1.depositRelayerFeePct,
            currentSpokePoolTime
          )
        )
    ).to.be.reverted;
    // Re-enable route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, constants_1.destinationChainId, true);
    // Cannot deposit with invalid relayer fee.
    await (0, utils_1.expect)(
      spokePool.connect(depositor).deposit(
        ...(0, SpokePool_Fixture_1.getDepositParams)(
          recipient.address,
          erc20.address,
          constants_1.amountToDeposit,
          constants_1.destinationChainId,
          (0, utils_1.toWei)("1"), // Fee > 50%
          currentSpokePoolTime
        )
      )
    ).to.be.reverted;
    // Cannot deposit invalid quote fee.
    await (0, utils_1.expect)(
      spokePool.connect(depositor).deposit(
        ...(0, SpokePool_Fixture_1.getDepositParams)(
          recipient.address,
          erc20.address,
          constants_1.amountToDeposit,
          constants_1.destinationChainId,
          constants_1.depositRelayerFeePct,
          (0, utils_1.toBN)(currentSpokePoolTime).add((0, utils_1.toBN)("700")) // > 10 mins in future
        )
      )
    ).to.be.reverted;
    await (0, utils_1.expect)(
      spokePool.connect(depositor).deposit(
        ...(0, SpokePool_Fixture_1.getDepositParams)(
          recipient.address,
          erc20.address,
          constants_1.amountToDeposit,
          constants_1.destinationChainId,
          constants_1.depositRelayerFeePct,
          (0, utils_1.toBN)(currentSpokePoolTime).sub((0, utils_1.toBN)("700")) // > 10 mins in future
        )
      )
    ).to.be.reverted;
  });
});
