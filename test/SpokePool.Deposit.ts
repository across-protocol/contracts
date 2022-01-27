import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, seedWallet, toBN, toWei } from "./utils";
import { deploySpokePoolTestHelperContracts, enableRoutes } from "./SpokePool.Fixture";
import { amountToSeedWallets, amountToDeposit, depositDestinationChainId, depositRelayerFeePct } from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, unwhitelistedErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress;

describe("SpokePool Depositor Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient] = await ethers.getSigners();
    ({ weth, erc20, spokePool, unwhitelistedErc20 } = await deploySpokePoolTestHelperContracts(depositor));

    // mint some fresh tokens and deposit ETH for weth for the depositor.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);

    // Whitelist origin => destination token routes:
    await enableRoutes(spokePool, [
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
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          erc20.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime
        )
    )
      .to.emit(spokePool, "FundsDeposited")
      .withArgs(
        depositDestinationChainId,
        amountToDeposit,
        0,
        depositRelayerFeePct,
        currentSpokePoolTime,
        erc20.address,
        recipient.address,
        depositor.address
      );

    // The collateral should have transferred from depositor to contract.
    expect(await erc20.balanceOf(depositor.address)).to.equal(amountToSeedWallets.sub(amountToDeposit));
    expect(await erc20.balanceOf(spokePool.address)).to.equal(amountToDeposit);

    // Deposit nonce should increment.
    expect(await spokePool.numberOfDeposits()).to.equal(1);
  });
  it("Depositing ETH correctly wraps into WETH", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();

    // Fails if msg.value > 0 but doesn't match amount to deposit.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          weth.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime,
          { value: 1 }
        )
    ).to.be.reverted;

    await expect(() =>
      spokePool
        .connect(depositor)
        .deposit(
          weth.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime,
          { value: amountToDeposit }
        )
    ).to.changeEtherBalances([depositor, weth], [amountToDeposit.mul(toBN("-1")), amountToDeposit]); // ETH should transfer from depositor to WETH contract.

    // WETH balance for user should be same as start, but WETH balancein pool should increase.
    expect(await weth.balanceOf(depositor.address)).to.equal(amountToSeedWallets);
    expect(await weth.balanceOf(spokePool.address)).to.equal(amountToDeposit);
  });
  it("Depositing ETH with msg.value = 0 pulls WETH from depositor", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();
    await expect(() =>
      spokePool
        .connect(depositor)
        .deposit(
          weth.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime,
          { value: 0 }
        )
    ).to.changeTokenBalances(weth, [depositor, spokePool], [amountToDeposit.mul(toBN("-1")), amountToDeposit]);
  });
  it("General failure cases", async function () {
    const currentSpokePoolTime = await spokePool.getCurrentTime();

    // Blocked if user hasn't approved token.
    await erc20.connect(depositor).approve(spokePool.address, 0);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          erc20.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime
        )
    ).to.be.reverted;
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);

    // Can only deposit whitelisted token.
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          unwhitelistedErc20.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime
        )
    ).to.be.reverted;

    // Cannot deposit disabled route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, depositDestinationChainId, false);
    await expect(
      spokePool
        .connect(depositor)
        .deposit(
          erc20.address,
          depositDestinationChainId,
          amountToDeposit,
          recipient.address,
          depositRelayerFeePct,
          currentSpokePoolTime
        )
    ).to.be.reverted;
    // Re-enable route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, depositDestinationChainId, true);

    // Cannot deposit with invalid relayer fee.
    await expect(
      spokePool.connect(depositor).deposit(
        erc20.address,
        depositDestinationChainId,
        amountToDeposit,
        recipient.address,
        toWei("1"), // Fee > 50%
        currentSpokePoolTime
      )
    ).to.be.reverted;

    // Cannot deposit invalid quote fee.
    await expect(
      spokePool.connect(depositor).deposit(
        erc20.address,
        depositDestinationChainId,
        amountToDeposit,
        recipient.address,
        depositRelayerFeePct,
        toBN(currentSpokePoolTime).add(toBN("700")) // > 10 mins in future
      )
    ).to.be.reverted;
    await expect(
      spokePool.connect(depositor).deposit(
        erc20.address,
        depositDestinationChainId,
        amountToDeposit,
        recipient.address,
        depositRelayerFeePct,
        toBN(currentSpokePoolTime).sub(toBN("700")) // > 10 mins in past
      )
    ).to.be.reverted;
  });
});
