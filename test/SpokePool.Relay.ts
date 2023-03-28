import { expect, Contract, ethers, SignerWithAddress, seedWallet, toWei, toBN, BigNumber, createFake } from "./utils";
import {
  spokePoolFixture,
  getRelayHash,
  modifyRelayHelper,
  getFillRelayParams,
  getFillRelayUpdatedFeeParams,
} from "./fixtures/SpokePool.Fixture";
import * as consts from "./constants";
import { MAX_UINT_VAL } from "@uma/common";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract, erc1271: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20, erc1271 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, consts.amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(relayer).approve(spokePool.address, consts.amountToDeposit);
  });
  it("Relaying ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      destErc20.address
    );

    // Partial relay:

    // Can't fill when paused:
    await spokePool.connect(depositor).pauseFills(true);
    await expect(spokePool.connect(relayer).fillRelay(...getFillRelayParams(relayData, consts.amountToRelay))).to.be
      .reverted;
    await spokePool.connect(depositor).pauseFills(false);

    // Must set repayment chain == destination chain for partial fills:
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(...getFillRelayParams(relayData, consts.amountToRelay, consts.repaymentChainId))
    ).to.be.revertedWith("invalid repayment chain");

    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(...getFillRelayParams(relayData, consts.amountToRelay, consts.destinationChainId))
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayData.amount,
        consts.amountToRelayPreFees,
        consts.amountToRelayPreFees,
        consts.destinationChainId,
        toBN(relayData.originChainId),
        toBN(relayData.destinationChainId),
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        toBN(relayData.depositId),
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient,
        relayData.message,
        [relayData.recipient, relayData.message, relayData.relayerFeePct, false]
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);

    // Fill count should be set. Note: even though this is a partial fill, the fill count should be set to the full
    // amount because we don't know if the rest of the relay will be slow filled or not.
    const fillCountIncrement = relayData.amount
      .mul(consts.oneHundredPct.sub(relayData.realizedLpFeePct))
      .div(consts.oneHundredPct);
    expect(await spokePool.fillCounter(relayData.destinationToken)).to.equal(fillCountIncrement);

    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = consts.amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount.mul(consts.totalPostFeesPct).div(toBN(consts.oneHundredPct));
    await spokePool
      .connect(relayer)
      .fillRelay(...getFillRelayParams(relayData, fullRelayAmount, consts.destinationChainId));
    expect(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(fullRelayAmountPostFees)
    );
    expect(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);

    // Fill amount should be equal to full relay amount.
    expect(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Repayment chain is set correctly", async function () {
    // Can set repayment chain if full fill.
    const { relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      destErc20.address
    );

    // Changed consts.amountToRelay to relayData.amount to make it a full fill
    await expect(
      spokePool.connect(relayer).fillRelay(...getFillRelayParams(relayData, relayData.amount, consts.repaymentChainId))
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayData.amount,
        relayData.amount,
        relayData.amount,
        consts.repaymentChainId,
        toBN(relayData.originChainId),
        toBN(relayData.destinationChainId),
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        toBN(relayData.depositId),
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient,
        relayData.message,
        [relayData.recipient, relayData.message, relayData.relayerFeePct, false]
      );

    // Repayment on another chain doesn't increment fill counter.
    expect(await spokePool.fillCounter(relayData.destinationToken)).to.equal(0);
  });
  it("Fill count increment local repayment", async function () {
    const { relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      destErc20.address
    );

    await spokePool
      .connect(relayer)
      .fillRelay(...getFillRelayParams(relayData, consts.amountToRelay, consts.destinationChainId));

    // Fill count should be set to the full fill amount (the rest is assumed to be slow filled).
    const fillCountIncrement = relayData.amount
      .mul(consts.oneHundredPct.sub(relayData.realizedLpFeePct))
      .div(consts.oneHundredPct);
    expect(await spokePool.fillCounter(relayData.destinationToken)).to.equal(fillCountIncrement);
  });
  it("Requested refund increments fill count", async function () {
    const { relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      destErc20.address
    );

    const maxFillCount = relayData.amount;

    await expect(
      spokePool.connect(relayer).requestRefund(
        destErc20.address,
        relayData.amount,
        consts.originChainId,
        relayData.realizedLpFeePct,
        relayData.depositId,
        11, // Use any block number for this test.
        maxFillCount
      )
    )
      .to.emit(spokePool, "RefundRequested")
      .withArgs(
        relayer.address,
        destErc20.address,
        relayData.amount,
        consts.originChainId,
        relayData.realizedLpFeePct,
        toBN(relayData.depositId),
        11,
        0
      );

    // Fill count should be set.
    const fillCountIncrement = relayData.amount
      .mul(consts.oneHundredPct.sub(relayData.realizedLpFeePct))
      .div(consts.oneHundredPct);
    expect(await spokePool.fillCounter(relayData.destinationToken)).to.equal(fillCountIncrement);

    // Reverts if max fill count or max fill amount is exceeded
    await expect(
      spokePool.connect(relayer).requestRefund(
        destErc20.address,
        MAX_UINT_VAL, // Too large
        consts.originChainId,
        relayData.realizedLpFeePct,
        relayData.depositId,
        0,
        maxFillCount
      )
    ).to.be.revertedWith("Amount too large");
    await expect(
      spokePool.connect(relayer).requestRefund(
        destErc20.address,
        relayData.amount,
        consts.originChainId,
        relayData.realizedLpFeePct,
        relayData.depositId,
        0,
        fillCountIncrement.sub(1) // Can't be less than existing fill counter
      )
    ).to.be.revertedWith("Above max count");
    await expect(
      spokePool.connect(relayer).requestRefund(
        destErc20.address,
        0, // Too small
        consts.originChainId,
        relayData.realizedLpFeePct,
        relayData.depositId,
        0,
        maxFillCount
      )
    ).to.be.revertedWith("Amount must be > 0");

    await expect(
      spokePool.connect(relayer).requestRefund(
        destErc20.address,
        relayData.amount,
        consts.originChainId,
        relayData.realizedLpFeePct,
        relayData.depositId,
        11, // Use any block number for this test.
        maxFillCount
      )
    )
      .to.emit(spokePool, "RefundRequested")
      .withArgs(
        relayer.address,
        destErc20.address,
        relayData.amount,
        consts.originChainId,
        relayData.realizedLpFeePct,
        toBN(relayData.depositId),
        11,
        1 // Incremented refund count.
      );
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      weth.address
    );

    const startingRecipientBalance = await recipient.getBalance();
    await spokePool
      .connect(relayer)
      .fillRelay(...getFillRelayParams(relayData, consts.amountToRelay, consts.destinationChainId));

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(consts.amountToRelay));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);
  });
  it("Relaying to contract recipient correctly calls contract and sends tokens", async function () {
    const acrossMessageHandler = await createFake("AcrossMessageHandlerMock");
    const { relayData } = getRelayHash(
      depositor.address,
      acrossMessageHandler.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      weth.address,
      undefined,
      undefined,
      undefined,
      "0x1234"
    );

    await spokePool
      .connect(relayer)
      .fillRelay(...getFillRelayParams(relayData, consts.amountToRelay, consts.destinationChainId));

    expect(acrossMessageHandler.handleAcrossMessage).to.have.been.calledOnceWith(
      weth.address,
      consts.amountToRelay,
      "0x1234"
    );

    // The collateral should have not unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(acrossMessageHandler.address)).to.equal(consts.amountToRelay);
  });
  it("Self-relay transfers no tokens", async function () {
    const largeRelayAmount = consts.amountToSeedWallets.mul(100);
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      relayer.address,
      consts.firstDepositId,
      consts.originChainId,
      consts.destinationChainId,
      weth.address,
      largeRelayAmount
    );

    // This should work, despite the amount being quite large.
    await spokePool
      .connect(relayer)
      .fillRelay(...getFillRelayParams(relayData, largeRelayAmount, consts.destinationChainId));

    // Balance should be the same as before.
    expect(await weth.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(largeRelayAmount);
  });
  it("General failure cases", async function () {
    // Fees set too high.
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getFillRelayParams(
            getRelayHash(
              depositor.address,
              recipient.address,
              consts.firstDepositId,
              consts.originChainId,
              consts.destinationChainId,
              destErc20.address,
              consts.amountToDeposit,
              toWei("0.5"),
              consts.depositRelayerFeePct
            ).relayData,
            consts.amountToRelay,
            consts.destinationChainId
          )
        )
    ).to.be.revertedWith("invalid fees");
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...getFillRelayParams(
            getRelayHash(
              depositor.address,
              recipient.address,
              consts.firstDepositId,
              consts.originChainId,
              consts.destinationChainId,
              destErc20.address,
              consts.amountToDeposit,
              consts.realizedLpFeePct,
              toWei("0.5")
            ).relayData,
            consts.amountToRelay,
            consts.destinationChainId
          )
        )
    ).to.be.revertedWith("invalid fees");

    // Relay already filled
    await spokePool.connect(relayer).fillRelay(
      ...getFillRelayParams(
        getRelayHash(
          depositor.address,
          recipient.address,
          consts.firstDepositId,
          consts.originChainId,
          consts.destinationChainId,
          destErc20.address
        ).relayData,
        consts.amountToDeposit, // Send the full relay amount
        consts.destinationChainId
      )
    );
    await expect(
      spokePool.connect(relayer).fillRelay(
        ...getFillRelayParams(
          getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            consts.destinationChainId,
            destErc20.address
          ).relayData,
          toBN("1"), // relay any amount
          consts.destinationChainId
        )
      )
    ).to.be.revertedWith("relay filled");
    await expect(
      spokePool.connect(relayer).fillRelay(
        ...getFillRelayParams(
          getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.repaymentChainId,
            consts.destinationChainId,
            destErc20.address
          ).relayData,
          toBN("1"), // relay any amount
          consts.destinationChainId,
          BigNumber.from(0)
        )
      )
    ).to.be.revertedWith("Above max count");
  });
  it("Can signal to relayer to use updated fee", async function () {
    await testUpdatedFeeSignaling(depositor.address);
  });
  it("EIP1271 - Can signal to relayer to use updated fee", async function () {
    await testUpdatedFeeSignaling(erc1271.address);
  });
  it("Can fill relay with updated fee by including proof of depositor's agreement", async function () {
    await testfillRelayWithUpdatedDeposit(depositor.address);
  });
  it("EIP1271 - Can fill relay with updated fee by including proof of depositor's agreement", async function () {
    await testfillRelayWithUpdatedDeposit(erc1271.address);
  });
  it("Updating relayer fee signature verification failure cases", async function () {
    await testUpdatedFeeSignatureFailCases(depositor.address);
  });
  it("EIP1271 - Updating relayer fee signature verification failure cases", async function () {
    await testUpdatedFeeSignatureFailCases(erc1271.address);
  });
});

async function testUpdatedFeeSignaling(depositorAddress: string) {
  const spokePoolChainId = await spokePool.chainId();
  const updatedMessage = "0x1234";
  const updatedRecipient = depositor.address;
  const { signature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    consts.firstDepositId.toString(),
    spokePoolChainId.toString(),
    depositor,
    updatedRecipient,
    updatedMessage
  );

  // Cannot set new relayer fee pct >= 50% or <= -50%
  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        toWei("0.5"),
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        signature
      )
  ).to.be.revertedWith("Invalid relayer fee");
  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        toWei("0.5").mul(-1),
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        signature
      )
  ).to.be.revertedWith("Invalid relayer fee");

  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        consts.modifiedRelayerFeePct,
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        signature
      )
  )
    .to.emit(spokePool, "RequestedSpeedUpDeposit")
    .withArgs(
      consts.modifiedRelayerFeePct,
      consts.firstDepositId,
      depositorAddress,
      updatedRecipient,
      updatedMessage,
      signature
    );

  // Reverts if any param passed to function is changed.
  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        relayer.address,
        consts.modifiedRelayerFeePct,
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        signature
      )
  ).to.be.reverted;

  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(depositorAddress, "0", consts.firstDepositId, updatedRecipient, updatedMessage, signature)
  ).to.be.reverted;

  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        consts.modifiedRelayerFeePct,
        consts.firstDepositId + 1,
        updatedRecipient,
        updatedMessage,
        signature
      )
  ).to.be.reverted;

  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        consts.modifiedRelayerFeePct,
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        "0xrandombytes"
      )
  ).to.be.reverted;
  const { signature: incorrectOriginChainIdSignature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    consts.firstDepositId.toString(),
    consts.originChainId.toString(),
    depositor,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .speedUpDeposit(
        depositorAddress,
        consts.modifiedRelayerFeePct,
        consts.firstDepositId,
        updatedRecipient,
        updatedMessage,
        incorrectOriginChainIdSignature
      )
  ).to.be.reverted;
}

async function testfillRelayWithUpdatedDeposit(depositorAddress: string) {
  // The relay should succeed just like before with the same amount of tokens pulled from the relayer's wallet,
  // however the filled amount should have increased since the proportion of the relay filled would increase with a
  // higher fee.
  const { relayHash, relayData } = getRelayHash(
    depositorAddress,
    recipient.address,
    consts.firstDepositId,
    consts.originChainId,
    consts.destinationChainId,
    destErc20.address
  );

  const updatedRecipient = depositor.address;
  const updatedMessage = "0x1234";

  const { signature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    relayData.depositId,
    relayData.originChainId,
    depositor,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .fillRelayWithUpdatedDeposit(
        ...getFillRelayUpdatedFeeParams(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          signature,
          consts.destinationChainId,
          updatedRecipient,
          updatedMessage
        )
      )
  )
    .to.emit(spokePool, "FilledRelay")
    .withArgs(
      relayData.amount,
      consts.amountToRelayPreModifiedFees,
      consts.amountToRelayPreModifiedFees,
      consts.destinationChainId,
      toBN(relayData.originChainId),
      toBN(relayData.destinationChainId),
      relayData.relayerFeePct,
      relayData.realizedLpFeePct,
      toBN(relayData.depositId),
      relayData.destinationToken,
      relayer.address,
      relayData.depositor,
      relayData.recipient,
      relayData.message,
      [
        updatedRecipient,
        updatedMessage,
        consts.modifiedRelayerFeePct, // Applied relayer fee % should be diff from original fee %.
        false,
      ]
    );

  // The collateral should have transferred from relayer to recipient.
  expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
  expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

  // Fill amount should be be set taking into account modified fees.
  expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreModifiedFees);
}

async function testUpdatedFeeSignatureFailCases(depositorAddress: string) {
  const { relayData } = getRelayHash(
    depositorAddress,
    recipient.address,
    consts.firstDepositId,
    consts.originChainId,
    consts.destinationChainId,
    destErc20.address
  );

  const updatedRecipient = depositor.address;
  const updatedMessage = "0x1234";

  // Message hash doesn't contain the modified fee passed as a function param.
  const { signature: incorrectFeeSignature } = await modifyRelayHelper(
    consts.incorrectModifiedRelayerFeePct,
    relayData.depositId,
    relayData.originChainId,
    depositor,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .fillRelayWithUpdatedDeposit(
        ...getFillRelayUpdatedFeeParams(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          incorrectFeeSignature,
          consts.destinationChainId,
          updatedRecipient,
          updatedMessage
        )
      )
  ).to.be.revertedWith("invalid signature");

  // Relay data depositID and originChainID don't match data included in relay hash
  const { signature: incorrectDepositIdSignature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    relayData.depositId + "1",
    relayData.originChainId,
    depositor,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .fillRelayWithUpdatedDeposit(
        ...getFillRelayUpdatedFeeParams(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          incorrectDepositIdSignature,
          consts.destinationChainId,
          updatedRecipient,
          updatedMessage
        )
      )
  ).to.be.revertedWith("invalid signature");
  const { signature: incorrectChainIdSignature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    relayData.depositId,
    relayData.originChainId + "1",
    depositor,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .fillRelayWithUpdatedDeposit(
        ...getFillRelayUpdatedFeeParams(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          incorrectChainIdSignature,
          consts.destinationChainId,
          updatedRecipient,
          updatedMessage
        )
      )
  ).to.be.revertedWith("invalid signature");

  // Message hash must be signed by depositor passed in function params.
  const { signature: incorrectSignerSignature } = await modifyRelayHelper(
    consts.modifiedRelayerFeePct,
    relayData.depositId,
    relayData.originChainId,
    relayer,
    updatedRecipient,
    updatedMessage
  );
  await expect(
    spokePool
      .connect(relayer)
      .fillRelayWithUpdatedDeposit(
        ...getFillRelayUpdatedFeeParams(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          incorrectSignerSignature,
          consts.destinationChainId,
          updatedRecipient,
          updatedMessage
        )
      )
  ).to.be.revertedWith("invalid signature");
}
