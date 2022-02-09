import { expect, Contract, ethers, SignerWithAddress, seedWallet, toWei, toBN } from "./utils";
import { spokePoolFixture, enableRoutes, getRelayHash } from "./SpokePool.Fixture";
import * as consts from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, consts.amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(relayer).approve(spokePool.address, consts.amountToDeposit);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [
      {
        originToken: erc20.address,
      },
      {
        originToken: weth.address,
      },
    ]);
  });
  it("Relaying ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const { relayHash, relayData, relayDataValues } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );

    await expect(
      spokePool.connect(relayer).fillRelay(...relayDataValues, consts.amountToRelay, consts.repaymentChainId)
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        consts.amountToRelayPreFees,
        consts.amountToRelayPreFees,
        consts.repaymentChainId,
        relayData.originChainId,
        relayData.depositId,
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);

    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = consts.amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount.mul(consts.totalPostFeesPct).div(toBN(consts.oneHundredPct));
    const amountRemainingInRelay = fullRelayAmount.sub(consts.amountToRelayPreFees);
    // const amountRemainingInRelayPostFees = amountRemainingInRelay.mul(totalPostFeesPct).div(toBN(oneHundredPct));
    await expect(spokePool.connect(relayer).fillRelay(...relayDataValues, fullRelayAmount, consts.repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        fullRelayAmount,
        amountRemainingInRelay,
        consts.repaymentChainId,
        relayData.originChainId,
        relayData.depositId,
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );
    expect(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(fullRelayAmountPostFees)
    );
    expect(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);

    // Fill amount should be equal to full relay amount.
    expect(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData, relayDataValues } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      weth.address
    );

    const startingRecipientBalance = await recipient.getBalance();
    await expect(
      spokePool.connect(relayer).fillRelay(...relayDataValues, consts.amountToRelay, consts.repaymentChainId)
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        consts.amountToRelayPreFees,
        consts.amountToRelayPreFees,
        consts.repaymentChainId,
        relayData.originChainId,
        relayData.depositId,
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(consts.amountToRelay));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);
  });
  it("General failure cases", async function () {
    // Fees set too high.
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address,
            consts.amountToDeposit.toString(),
            toWei("0.51").toString(),
            toWei("0.5").toString()
          ).relayDataValues,
          consts.amountToRelay,
          consts.repaymentChainId
        )
    ).to.be.reverted;
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address,
            consts.amountToDeposit.toString(),
            toWei("0.5").toString(),
            toWei("0.51").toString()
          ).relayDataValues,
          consts.amountToRelay,
          consts.repaymentChainId
        )
    ).to.be.reverted;
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address,
            consts.amountToDeposit.toString(),
            toWei("0.5").toString(),
            toWei("0.5").toString()
          ).relayDataValues,
          consts.amountToRelay,
          consts.repaymentChainId
        )
    ).to.be.reverted;

    // Fill amount cannot be 0.
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address
          ).relayDataValues,
          "0",
          consts.repaymentChainId
        )
    ).to.be.reverted;

    // Relay already filled
    await spokePool.connect(relayer).fillRelay(
      ...getRelayHash(
        depositor.address,
        recipient.address,
        consts.firstDepositId,
        consts.originChainId,
        destErc20.address
      ).relayDataValues,
      consts.amountToDeposit, // Send the full relay amount
      consts.repaymentChainId
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address
          ).relayDataValues,
          "1",
          consts.repaymentChainId
        )
    ).to.be.reverted;
  });
});
