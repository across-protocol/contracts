import {
  expect,
  Contract,
  ethers,
  SignerWithAddress,
  seedWallet,
  toWei,
  toBN,
  BigNumber,
  createFake,
  keccak256,
  defaultAbiCoder,
  getParamType,
} from "../utils/utils";
import {
  spokePoolFixture,
  getRelayHash,
  modifyRelayHelper,
  getFillRelayParams,
  getFillRelayUpdatedFeeParams,
  USSRelayData,
  USSRelayExecutionParams,
  FillStatus,
  FillType,
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
    const { relayData } = getRelayHash(
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
        [relayData.recipient, relayData.message, relayData.relayerFeePct, false, "0"]
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

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
        [relayData.recipient, relayData.message, relayData.relayerFeePct, false, "0"]
      );
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayData } = getRelayHash(
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
      false,
      relayer.address,
      "0x1234"
    );
  });
  it("Handler is called with correct params", async function () {
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

    // Handler is called with full fill and relayer address.
    await spokePool
      .connect(depositor)
      .fillRelay(...getFillRelayParams(relayData, relayData.amount, consts.destinationChainId));
    expect(acrossMessageHandler.handleAcrossMessage).to.have.been.calledOnceWith(
      weth.address,
      relayData.amount.mul(consts.totalPostFeesPct).div(toBN(consts.oneHundredPct)),
      true, // True because fill completed deposit.
      depositor.address, // Custom relayer
      "0x1234"
    );
  });
  it("Self-relay transfers no tokens", async function () {
    const largeRelayAmount = consts.amountToSeedWallets.mul(100);
    const { relayData } = getRelayHash(
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
  describe("fill USS", function () {
    let relayData: USSRelayData;
    beforeEach(async function () {
      const fillDeadline = (await spokePool.getCurrentTime()).toNumber() + 1000;
      relayData = {
        depositor: depositor.address,
        recipient: recipient.address,
        exclusiveRelayer: relayer.address,
        inputToken: erc20.address,
        outputToken: destErc20.address,
        inputAmount: consts.amountToDeposit,
        outputAmount: consts.amountToDeposit,
        originChainId: consts.originChainId,
        destinationChainId: consts.destinationChainId,
        depositId: consts.firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
    });
    it("succeeds with expected params", async function () {
      await spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId);
    });
    describe("_fillRelay internal logic", function () {
      // _fillRelay takes a USSRelayExecutionParams object as a param. This function returns the correct object
      // as a convenience.
      async function getRelayExecutionParams(_relayData: USSRelayData): Promise<USSRelayExecutionParams> {
        const paramType = await getParamType("MockSpokePool", "fillUSSRelay", "relayData");
        return {
          relay: _relayData,
          relayHash: keccak256(defaultAbiCoder.encode([paramType!], [_relayData])),
          updatedOutputAmount: _relayData.outputAmount,
          updatedRecipient: _relayData.recipient,
          updatedMessage: _relayData.message,
          repaymentChainId: consts.repaymentChainId,
        };
      }
      it("expired fill deadline reverts", async function () {
        const _relay = {
          ...relayData,
          fillDeadline: 0, // Will always be less than SpokePool.currentTime so should expire.
        };
        const relayExecution = await getRelayExecutionParams(_relay);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.be.revertedWith("ExpiredFillDeadline");
      });
      it("relay hash already marked filled", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        await spokePool.setFillStatus(relayExecution.relayHash, FillStatus.Filled);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.be.revertedWith("RelayFilled");
      });
      it("fast fill replacing speed up request emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        await spokePool.setFillStatus(relayExecution.relayHash, FillStatus.RequestedSlowFill);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledUSSRelay")
          .withArgs(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.address,
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            [
              relayExecution.updatedRecipient,
              relayExecution.updatedMessage,
              relayExecution.updatedOutputAmount,
              // Testing that this FillType is not "FastFill"
              FillType.ReplacedSlowFill,
            ]
          );
      });
      it("slow fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        await destErc20.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            true // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledUSSRelay")
          .withArgs(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.address,
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            [
              relayExecution.updatedRecipient,
              relayExecution.updatedMessage,
              relayExecution.updatedOutputAmount,
              // Testing that this FillType is "SlowFill"
              FillType.SlowFill,
            ]
          );
      });
      it("fast fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledUSSRelay")
          .withArgs(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.address,
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            [
              relayExecution.updatedRecipient,
              relayExecution.updatedMessage,
              relayExecution.updatedOutputAmount,
              // Testing that this FillType is "SlowFill"
              FillType.FastFill,
            ]
          );
      });
      it("does not transfer funds if msg.sender is recipient unless its a slow fill", async function () {
        const _relayData = {
          ...relayData,
          // Set recipient == relayer
          recipient: relayer.address,
        };
        const relayExecution = await getRelayExecutionParams(_relayData);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.not.emit(destErc20, "Transfer");
      });
      it("sends updatedOutputAmount to updatedRecipient", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        const _relayExecution = {
          ...relayExecution,
          // Overwrite amount to send to be double the original amount
          updatedOutputAmount: consts.amountToDeposit.mul(2),
          // Overwrite recipient to depositor which is not the same as the original recipient
          updatedRecipient: depositor.address,
        };
        expect(_relayExecution.updatedRecipient).to.not.equal(relayExecution.updatedRecipient);
        expect(_relayExecution.updatedOutputAmount).to.not.equal(relayExecution.updatedOutputAmount);
        await destErc20.connect(relayer).approve(spokePool.address, _relayExecution.updatedOutputAmount);
        await expect(() =>
          spokePool.connect(relayer).fillRelayUSSInternal(
            _relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.changeTokenBalance(destErc20, depositor, consts.amountToDeposit.mul(2));
      });
      it("unwraps native token if sending to EOA otherwise sends wrapped ERC20", async function () {
        const _relayData = {
          ...relayData,
          outputToken: weth.address,
        };
        const relayExecution = await getRelayExecutionParams(_relayData);
        await expect(() =>
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.changeEtherBalance(recipient, relayExecution.updatedOutputAmount);
      });
      it("slow fills send native token out of spoke pool balance", async function () {
        const _relayData = {
          ...relayData,
          outputToken: weth.address,
        };
        const relayExecution = await getRelayExecutionParams(_relayData);
        await weth.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        await expect(() =>
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            true // isSlowFill
          )
        ).to.changeEtherBalance(recipient, relayExecution.updatedOutputAmount);
      });
      it("slow fills send non-native token out of spoke pool balance", async function () {
        const relayExecution = await getRelayExecutionParams(relayData);
        await destErc20.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        await expect(() =>
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            true // isSlowFill
          )
        ).to.changeTokenBalance(destErc20, spokePool, relayExecution.updatedOutputAmount.mul(-1));
      });
      it("if recipient is contract that implements message handler, calls message handler", async function () {
        // Does nothing if message length is 0
        const acrossMessageHandler = await createFake("AcrossMessageHandlerMock");
        const _relayData = {
          ...relayData,
          recipient: acrossMessageHandler.address,
          message: "0x1234",
        };
        const relayExecution = await getRelayExecutionParams(_relayData);

        // Handler is called with expected params.
        await spokePool.connect(relayer).fillRelayUSSInternal(
          relayExecution,
          relayer.address,
          false // isSlowFill
        );
        expect(acrossMessageHandler.handleUSSAcrossMessage).to.have.been.calledOnceWith(
          _relayData.outputToken,
          relayExecution.updatedOutputAmount,
          relayer.address, // Custom relayer
          _relayData.message
        );
      });
    });
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
  const acrossMessageHandler = await createFake("AcrossMessageHandlerMock");
  const updatedRecipient = acrossMessageHandler.address;
  const updatedMessage = "0x1234";

  // The relay should succeed just like before with the same amount of tokens pulled from the relayer's wallet,
  // however the filled amount should have increased since the proportion of the relay filled would increase with a
  // higher fee.
  const { relayHash, relayData } = getRelayHash(
    depositorAddress,
    depositor.address,
    consts.firstDepositId,
    consts.originChainId,
    consts.destinationChainId,
    destErc20.address
  );
  expect(relayData.message).to.not.equal(updatedMessage);
  expect(relayData.recipient).to.not.equal(updatedRecipient);

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
        "0",
      ]
    );

  // Check that updated message and recipient are used with executed fill:
  const amountActuallySent = await destErc20.balanceOf(acrossMessageHandler.address);
  expect(acrossMessageHandler.handleAcrossMessage).to.have.been.calledOnceWith(
    relayData.destinationToken,
    amountActuallySent,
    false,
    relayer.address,
    updatedMessage
  );

  // The collateral should have transferred from relayer to recipient.
  const relayerBalance = await destErc20.balanceOf(relayer.address);
  const expectedRelayerBalance = consts.amountToSeedWallets.sub(consts.amountToRelay);

  // Note: We need to add an error bound of 1 wei to the expected balance because of the possibility
  // of rounding errors with the modified fees. The unmodified fees result in clean numbers but the modified fee does not.
  expect(relayerBalance.gte(expectedRelayerBalance.sub(1)) || relayerBalance.lte(expectedRelayerBalance.add(1))).to.be
    .true;
  const recipientBalance = amountActuallySent;
  const expectedRecipientBalance = consts.amountToRelay;
  expect(recipientBalance.gte(expectedRecipientBalance.sub(1)) || recipientBalance.lte(expectedRecipientBalance.add(1)))
    .to.be.true;
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
