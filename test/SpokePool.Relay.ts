import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress, seedWallet, toWei, toBN } from "./utils";
import { spokePoolFixture, enableRoutes, getRelayHash, modifyRelayHelper } from "./SpokePool.Fixture";
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
  modifiedRelayerFeePct,
  incorrectModifiedRelayerFeePct,
  amountToRelayPreModifiedFees,
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
    const { relayHash, relayData, relayDataValues } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      destErc20.address
    );

    await expect(spokePool.connect(relayer).fillRelay(...relayDataValues, amountToRelay, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        amountToRelayPreFees,
        amountToRelayPreFees,
        repaymentChainId,
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
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreFees);

    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount.mul(totalPostFeesPct).div(toBN(oneHundredPct));
    const amountRemainingInRelay = fullRelayAmount.sub(amountToRelayPreFees);
    // const amountRemainingInRelayPostFees = amountRemainingInRelay.mul(totalPostFeesPct).div(toBN(oneHundredPct));
    await expect(spokePool.connect(relayer).fillRelay(...relayDataValues, fullRelayAmount, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        fullRelayAmount,
        amountRemainingInRelay,
        repaymentChainId,
        relayData.originChainId,
        relayData.depositId,
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(fullRelayAmountPostFees));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);

    // Fill amount should be equal to full relay amount.
    expect(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData, relayDataValues } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      weth.address
    );

    const startingRecipientBalance = await recipient.getBalance();
    await expect(spokePool.connect(relayer).fillRelay(...relayDataValues, amountToRelay, repaymentChainId))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        amountToRelayPreFees,
        amountToRelayPreFees,
        repaymentChainId,
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
          ).relayDataValues,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.revertedWith("invalid fees");
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
          ).relayDataValues,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.revertedWith("invalid fees");
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
          ).relayDataValues,
          amountToRelay,
          repaymentChainId
        )
    ).to.be.revertedWith("invalid fees");

    // Relay already filled
    await spokePool.connect(relayer).fillRelay(
      ...getRelayHash(depositor.address, recipient.address, firstDepositId, originChainId, destErc20.address)
        .relayDataValues,
      amountToDeposit, // Send the full relay amount
      repaymentChainId
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getRelayHash(depositor.address, recipient.address, firstDepositId, originChainId, destErc20.address)
            .relayDataValues,
          "1",
          repaymentChainId
        )
    ).to.be.revertedWith("relay filled");
  });
  it("Can fill relay with updated fee by including proof of depositor's agreement", async function () {
    // The relay should succeed just like before with the same amount of tokens pulled from the relayer's wallet,
    // however the filled amount should have increased since the proportion of the relay filled would increase with a
    // higher fee.
    const { relayHash, relayData, relayDataValues } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      destErc20.address
    );
    const { signature } = await modifyRelayHelper(
      modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    // Note: modifiedRelayFeePct is inserted in-place into middle of the same params passed to fillRelay
    relayDataValues.splice(5, 0, modifiedRelayerFeePct.toString());
    await expect(
      spokePool.connect(relayer).fillRelayWithUpdatedFee(...relayDataValues, amountToRelay, repaymentChainId, signature)
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        amountToRelayPreModifiedFees,
        amountToRelayPreModifiedFees,
        repaymentChainId,
        relayData.originChainId,
        relayData.depositId,
        modifiedRelayerFeePct, // The relayer fee % emitted in event should change
        relayData.realizedLpFeePct,
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(amountToRelay);

    // Fill amount should be be set taking into account modified fees.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreModifiedFees);
  });
  it("Updating relayer fee signature verification failure cases", async function () {
    const { relayDataValues, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      firstDepositId,
      originChainId,
      destErc20.address
    );
    // Note: modifiedRelayFeePct is inserted in-place into middle of the same params passed to fillRelay
    relayDataValues.splice(5, 0, modifiedRelayerFeePct.toString());

    // Message hash doesn't contain the modified fee passed as a function param.
    const { signature: incorrectFeeSignature } = await modifyRelayHelper(
      incorrectModifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(...relayDataValues, amountToRelay, repaymentChainId, incorrectFeeSignature)
    ).to.be.revertedWith("invalid signature");

    // Relay data depositID and originChainID don't match data included in relay hash
    const { signature: incorrectDepositIdSignature } = await modifyRelayHelper(
      incorrectModifiedRelayerFeePct,
      relayData.depositId + "1",
      relayData.originChainId,
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(...relayDataValues, amountToRelay, repaymentChainId, incorrectDepositIdSignature)
    ).to.be.revertedWith("invalid signature");
    const { signature: incorrectChainIdSignature } = await modifyRelayHelper(
      incorrectModifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId + "1",
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(...relayDataValues, amountToRelay, repaymentChainId, incorrectChainIdSignature)
    ).to.be.revertedWith("invalid signature");

    // Message hash must be signed by depositor passed in function params.
    const { signature: incorrectSignerSignature } = await modifyRelayHelper(
      modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      relayer
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(...relayDataValues, amountToRelay, repaymentChainId, incorrectSignerSignature)
    ).to.be.revertedWith("invalid signature");
  });
});
