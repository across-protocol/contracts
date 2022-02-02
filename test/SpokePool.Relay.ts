import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, seedWallet, toWei, toBN } from "./utils";
import { spokePoolFixture, enableRoutes, getRelayHash } from "./SpokePool.Fixture";
import {
  amountToSeedWallets,
  amountToDeposit,
  amountToRelay,
  amountToRelayPreFees,
  totalPostFeesPct,
  originChainId,
  repaymentChainId,
  firstDepositId,
  oneHundredPct,
} from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, amountToDeposit);
    await weth.connect(relayer).approve(spokePool.address, amountToDeposit);

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
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      destErc20.address
    );

    await expect(spokePool.connect(relayer).fillRelay(...relayData, amountToRelay, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(relayHash, amountToRelayPreFees, repaymentChainId, amountToRelay, relayer.address, relayData);

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreFees);

    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount.mul(totalPostFeesPct).div(toBN(oneHundredPct));
    const amountRemainingInRelay = fullRelayAmount.sub(amountToRelayPreFees);
    const amountRemainingInRelayPostFees = amountRemainingInRelay.mul(totalPostFeesPct).div(toBN(oneHundredPct));
    await expect(spokePool.connect(relayer).fillRelay(...relayData, fullRelayAmount, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        fullRelayAmount,
        repaymentChainId,
        amountRemainingInRelayPostFees,
        relayer.address,
        relayData
      );
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(fullRelayAmountPostFees));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);

    // Fill amount should be equal to full relay amount.
    expect(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      weth.address
    );

    const startingRecipientBalance = await recipient.getBalance();
    await expect(spokePool.connect(relayer).fillRelay(...relayData, amountToRelay, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(relayHash, amountToRelayPreFees, repaymentChainId, amountToRelay, relayer.address, relayData);

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(amountToRelay));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreFees);
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
            firstDepositId,
            originChainId,
            destErc20.address,
            amountToDeposit.toString(),
            toWei("0.51").toString(),
            toWei("0.5").toString()
          ).relayData,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.reverted;
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            firstDepositId,
            originChainId,
            destErc20.address,
            amountToDeposit.toString(),
            toWei("0.5").toString(),
            toWei("0.51").toString()
          ).relayData,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.reverted;
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(
            depositor.address,
            recipient.address,
            firstDepositId,
            originChainId,
            destErc20.address,
            amountToDeposit.toString(),
            toWei("0.5").toString(),
            toWei("0.5").toString()
          ).relayData,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.reverted;

    // Fill amount cannot be 0.
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(depositor.address, recipient.address, firstDepositId, originChainId, destErc20.address)
            .relayData,
          "0",
          repaymentChainId
        )
    ).to.be.reverted;

    // Relay already filled
    await spokePool.connect(relayer).fillRelay(
      ...getRelayHash(depositor.address, recipient.address, firstDepositId, originChainId, destErc20.address).relayData,
      amountToDeposit, // Send the full relay amount
      repaymentChainId
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(depositor.address, recipient.address, firstDepositId, originChainId, destErc20.address)
            .relayData,
          "1",
          repaymentChainId
        )
    ).to.be.reverted;
  });
});
