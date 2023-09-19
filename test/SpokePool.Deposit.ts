import { BigNumber } from "ethers";
import { expect, ethers, Contract, SignerWithAddress, seedWallet, toBN, toWei } from "../utils/utils";
import { spokePoolFixture, enableRoutes, getDepositParams } from "./fixtures/SpokePool.Fixture";
import {
  amountToSeedWallets,
  amountToDeposit,
  destinationChainId,
  depositRelayerFeePct,
  maxUint256,
} from "./constants";

describe("SpokePool Depositor Logic", async function () {
  let spokePool: Contract, weth: Contract, erc20: Contract, unwhitelistedErc20: Contract;
  let depositor: SignerWithAddress, recipient: SignerWithAddress;
  let currentSpokePoolTime: BigNumber;

  beforeEach(async function () {
    [depositor, recipient] = await ethers.getSigners();
    ({ weth, erc20, spokePool, unwhitelistedErc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for the depositor.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);

    currentSpokePoolTime = await spokePool.getCurrentTime();
  });

  it("Depositing ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const revertReason = "Paused deposits";

    // Can't deposit when paused:
    await spokePool.connect(depositor).pauseDeposits(true);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.be.revertedWith(revertReason);

    await spokePool.connect(depositor).pauseDeposits(false);

    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    )
      .to.emit(spokePool, "FundsDeposited")
      .withArgs(
        amountToDeposit,
        destinationChainId,
        destinationChainId,
        depositRelayerFeePct,
        0,
        currentSpokePoolTime,
        erc20.address,
        recipient.address,
        depositor.address,
        "0x"
      );

    // The collateral should have transferred from depositor to contract.
    expect(await erc20.balanceOf(depositor.address)).to.equal(amountToSeedWallets.sub(amountToDeposit));
    expect(await erc20.balanceOf(spokePool.address)).to.equal(amountToDeposit);

    // Deposit nonce should increment.
    expect(await spokePool.numberOfDeposits()).to.equal(1);

    // Count is correctly incremented.
    expect(await spokePool.depositCounter(erc20.address)).to.equal(amountToDeposit);
  });

  it("Depositing ETH correctly wraps into WETH", async function () {
    const revertReason = "msg.value must match amount";

    // Fails if msg.value > 0 but doesn't match amount to deposit.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            weth.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          ),
          { value: 1 }
        )
    ).to.be.revertedWith(revertReason);

    await expect(() =>
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            weth.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          ),
          { value: amountToDeposit }
        )
    ).to.changeEtherBalances([depositor, weth], [amountToDeposit.mul(toBN("-1")), amountToDeposit]); // ETH should transfer from depositor to WETH contract.

    // WETH balance for user should be same as start, but WETH balancein pool should increase.
    expect(await weth.balanceOf(depositor.address)).to.equal(amountToSeedWallets);
    expect(await weth.balanceOf(spokePool.address)).to.equal(amountToDeposit);
  });

  it("Depositing ETH with msg.value = 0 pulls WETH from depositor", async function () {
    await expect(() =>
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            weth.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          ),
          { value: 0 }
        )
    ).to.changeTokenBalances(weth, [depositor, spokePool], [amountToDeposit.mul(toBN("-1")), amountToDeposit]);
  });

  it("SpokePool is not approved to spend originToken", async function () {
    const insufficientAllowance = "ERC20: insufficient allowance";

    await erc20.connect(depositor).approve(spokePool.address, 0);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.be.revertedWith(insufficientAllowance);

    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.emit(spokePool, "FundsDeposited");
  });

  it("Deposit route is disabled", async function () {
    const revertReason = "Disabled route";

    // Verify that routes are disabled by default.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            unwhitelistedErc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.be.revertedWith(revertReason);

    // Verify that the route is enabled.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.emit(spokePool, "FundsDeposited");

    // Disable the route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, destinationChainId, false);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.be.revertedWith(revertReason);

    // Re-enable the route and verify that it works again.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, destinationChainId, true);
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime,
            maxUint256
          )
        )
    ).to.emit(spokePool, "FundsDeposited");
  });

  it("Relayer fee is invalid", async function () {
    const revertReason = "Invalid relayer fee";

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams(
          recipient.address,
          erc20.address,
          amountToDeposit,
          destinationChainId,
          toWei("1"), // Fee > 50%
          currentSpokePoolTime,
          maxUint256
        )
      )
    ).to.be.revertedWith(revertReason);
  });

  it("quoteTimestamp is out of range", async function () {
    const revertReason = "invalid quote time";
    const quoteTimeBuffer = await spokePool.depositQuoteTimeBuffer();

    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            toBN(currentSpokePoolTime).add(quoteTimeBuffer + 1),
            maxUint256
          )
        )
    ).to.be.revertedWith(revertReason);

    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            toBN(currentSpokePoolTime).sub(quoteTimeBuffer + 1),
            maxUint256
          )
        )
    ).to.be.revertedWith(revertReason);

    // quoteTimestamp at max age.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            currentSpokePoolTime.sub(quoteTimeBuffer),
            maxUint256
          )
        )
    ).to.emit(spokePool, "FundsDeposited");
  });

  it("quoteTimestamp is set correctly by depositNow()", async function () {
    await expect(
      spokePool
        .connect(depositor)
        .depositNow(
          recipient.address,
          erc20.address,
          amountToDeposit.toString(),
          destinationChainId.toString(),
          depositRelayerFeePct.toString(),
          "0x",
          maxUint256
        )
    )
      .to.emit(spokePool, "FundsDeposited")
      .withArgs(
        amountToDeposit,
        destinationChainId,
        destinationChainId,
        depositRelayerFeePct,
        0,
        currentSpokePoolTime,
        erc20.address,
        recipient.address,
        depositor.address,
        "0x"
      );
  });

  it("maxCount is too low", async function () {
    const revertReason = "Above max count";

    // Setting max count to be smaller than the sum of previous deposits should fail.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          ...getDepositParams(
            recipient.address,
            erc20.address,
            amountToDeposit,
            destinationChainId,
            depositRelayerFeePct,
            toBN(currentSpokePoolTime),
            maxUint256
          )
        )
    ).to.emit(spokePool, "FundsDeposited");

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams(
          recipient.address,
          erc20.address,
          amountToDeposit,
          destinationChainId,
          depositRelayerFeePct,
          toBN(currentSpokePoolTime),
          amountToDeposit.sub(1) // Less than the previous transaction's deposit amount.
        )
      )
    ).to.be.revertedWith(revertReason);
  });
});
