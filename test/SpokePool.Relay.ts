import {
  expect,
  Contract,
  ethers,
  SignerWithAddress,
  seedWallet,
  createFake,
  randomAddress,
  createRandomBytes32,
  BigNumber,
} from "../utils/utils";
import {
  spokePoolFixture,
  USSRelayData,
  USSRelayExecutionParams,
  FillStatus,
  FillType,
  getUpdatedUSSDepositSignature,
  getUSSRelayHash,
} from "./fixtures/SpokePool.Fixture";
import * as consts from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

// _fillRelay takes a USSRelayExecutionParams object as a param. This function returns the correct object
// as a convenience.
async function getRelayExecutionParams(
  _relayData: USSRelayData,
  destinationChainId: number
): Promise<USSRelayExecutionParams> {
  return {
    relay: _relayData,
    relayHash: getUSSRelayHash(_relayData, destinationChainId),
    updatedOutputAmount: _relayData.outputAmount,
    updatedRecipient: _relayData.recipient,
    updatedMessage: _relayData.message,
    repaymentChainId: consts.repaymentChainId,
  };
}

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
        depositId: consts.firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
    });
    describe("_fillRelay internal logic", function () {
      it("default status is unfilled", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Unfilled);
      });
      it("expired fill deadline reverts", async function () {
        const _relay = {
          ...relayData,
          fillDeadline: 0, // Will always be less than SpokePool.currentTime so should expire.
        };
        const relayExecution = await getRelayExecutionParams(_relay, consts.destinationChainId);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.be.revertedWith("ExpiredFillDeadline");
      });
      it("relay hash already marked filled", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("slow fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("fast fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
              FillType.FastFill,
            ]
          );
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("does not transfer funds if msg.sender is recipient unless its a slow fill", async function () {
        const _relayData = {
          ...relayData,
          // Set recipient == relayer
          recipient: relayer.address,
        };
        const relayExecution = await getRelayExecutionParams(_relayData, consts.destinationChainId);
        await expect(
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            false // isSlowFill
          )
        ).to.not.emit(destErc20, "Transfer");
      });
      it("sends updatedOutputAmount to updatedRecipient", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
      it("unwraps native token if sending to EOA", async function () {
        const _relayData = {
          ...relayData,
          outputToken: weth.address,
        };
        const relayExecution = await getRelayExecutionParams(_relayData, consts.destinationChainId);
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
        const relayExecution = await getRelayExecutionParams(_relayData, consts.destinationChainId);
        await weth.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        const initialSpokeBalance = await weth.balanceOf(spokePool.address);
        await expect(() =>
          spokePool.connect(relayer).fillRelayUSSInternal(
            relayExecution,
            relayer.address,
            true // isSlowFill
          )
        ).to.changeEtherBalance(recipient, relayExecution.updatedOutputAmount);
        const spokeBalance = await weth.balanceOf(spokePool.address);
        expect(spokeBalance).to.equal(initialSpokeBalance.sub(relayExecution.updatedOutputAmount));
      });
      it("slow fills send non-native token out of spoke pool balance", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
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
        const relayExecution = await getRelayExecutionParams(_relayData, consts.destinationChainId);

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
    describe("fillUSSRelay", function () {
      it("fills are not paused", async function () {
        await spokePool.pauseFills(true);
        await expect(spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId)).to.be.revertedWith(
          "Paused fills"
        );
      });
      it("reentrancy protected", async function () {
        const functionCalldata = spokePool.interface.encodeFunctionData("fillUSSRelay", [
          relayData,
          consts.repaymentChainId,
        ]);
        await expect(spokePool.connect(relayer).callback(functionCalldata)).to.be.revertedWith(
          "ReentrancyGuard: reentrant call"
        );
      });
      it("must be exclusive relayer before exclusivity deadline", async function () {
        const _relayData = {
          ...relayData,
          // Overwrite exclusive relayer and exclusivity deadline
          exclusiveRelayer: recipient.address,
          exclusivityDeadline: relayData.fillDeadline,
        };
        await expect(spokePool.connect(relayer).fillUSSRelay(_relayData, consts.repaymentChainId)).to.be.revertedWith(
          "NotExclusiveRelayer"
        );

        // Can send it after exclusivity deadline
        await expect(
          spokePool.connect(relayer).fillUSSRelay(
            {
              ..._relayData,
              exclusivityDeadline: 0,
            },
            consts.repaymentChainId
          )
        ).to.not.be.reverted;
      });
      it("calls _fillRelayUSS with  expected params", async function () {
        await expect(spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId))
          .to.emit(spokePool, "FilledUSSRelay")
          .withArgs(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            consts.repaymentChainId, // Should be passed-in repayment chain ID
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.address, // Should be equal to msg.sender of fillRelayUSS
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            [
              relayData.recipient, // updatedRecipient should be equal to recipient
              relayData.message, // updatedMessage should be equal to message
              relayData.outputAmount, // updatedOutputAmount should be equal to outputAmount
              // Should be FastFill
              FillType.FastFill,
            ]
          );
      });
    });
    describe("fillUSSRelayWithUpdatedDeposit", function () {
      let updatedOutputAmount: BigNumber, updatedRecipient: string, updatedMessage: string, signature: string;
      beforeEach(async function () {
        updatedOutputAmount = relayData.outputAmount.add(1);
        updatedRecipient = randomAddress();
        updatedMessage = createRandomBytes32();
        await destErc20.connect(relayer).approve(spokePool.address, updatedOutputAmount);
        signature = await getUpdatedUSSDepositSignature(
          depositor,
          relayData.depositId,
          relayData.originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage
        );
      });
      it("must be exclusive relayer before exclusivity deadline", async function () {
        const _relayData = {
          ...relayData,
          // Overwrite exclusive relayer and exclusivity deadline
          exclusiveRelayer: recipient.address,
          exclusivityDeadline: relayData.fillDeadline,
        };
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              _relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("NotExclusiveRelayer");

        // Even if not exclusive relayer, can send it after exclusivity deadline
        await expect(
          spokePool.connect(relayer).fillUSSRelayWithUpdatedDeposit(
            {
              ..._relayData,
              exclusivityDeadline: 0,
            },
            consts.repaymentChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            signature
          )
        ).to.not.be.reverted;

        // @dev: However note that if the relayer modifies the relay data in production such that it doesn't match a
        // deposit with the origin chain ID and deposit ID, then the relay will not be refunded. Therefore, this
        // function is not a backdoor to send an invalid fill.
      });
      it("Happy case: updates fill status for relay hash associated with original relay data", async function () {
        // Check event is emitted with updated params
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        )
          .to.emit(spokePool, "FilledUSSRelay")
          .withArgs(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            consts.repaymentChainId, // Should be passed-in repayment chain ID
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.address, // Should be equal to msg.sender
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            [
              // Should use passed-in updated params:
              updatedRecipient,
              updatedMessage,
              updatedOutputAmount,
              // Should be FastFill
              FillType.FastFill,
            ]
          );

        // Check fill status mapping is updated
        const relayExecution = await getRelayExecutionParams(relayData, consts.destinationChainId);
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("validates depositor signature", async function () {
        // Incorrect depositor
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              { ...relayData, depositor: relayer.address },
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect signature for new deposit ID
        const otherSignature = await getUpdatedUSSDepositSignature(
          depositor,
          relayData.depositId + 1,
          relayData.originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage
        );
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              otherSignature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect origin chain ID
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              { ...relayData, originChainId: relayData.originChainId + 1 },
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect deposit ID
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              { ...relayData, depositId: relayData.depositId + 1 },
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect updated output amount
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount.sub(1),
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect updated recipient
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              randomAddress(),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("invalid signature");

        // Incorrect updated message
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              createRandomBytes32()
            )
        ).to.be.revertedWith("invalid signature");
      });
      it("validates ERC-1271 depositor contract signature", async function () {
        // The MockERC1271 contract returns true for isValidSignature if the signature was signed by the contract's
        // owner, so using the depositor's signature should succeed and using someone else's signature should fail.
        const incorrectSignature = await getUpdatedUSSDepositSignature(
          relayer, // not depositor
          relayData.depositId,
          relayData.originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage
        );
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              { ...relayData, depositor: erc1271.address },
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              incorrectSignature
            )
        ).to.be.revertedWith("invalid signature");
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              { ...relayData, depositor: erc1271.address },
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.not.be.reverted;
      });
      it("cannot send updated fill after original fill", async function () {
        await spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId);
        await expect(
          spokePool
            .connect(relayer)
            .fillUSSRelayWithUpdatedDeposit(
              relayData,
              consts.repaymentChainId,
              updatedOutputAmount,
              updatedRecipient,
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("RelayFilled");
      });
      it("cannot send updated fill after slow fill", async function () {
        await spokePool
          .connect(relayer)
          .fillUSSRelayWithUpdatedDeposit(
            relayData,
            consts.repaymentChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            signature
          );
        await expect(spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId)).to.be.revertedWith(
          "RelayFilled"
        );
      });
    });
  });
});
