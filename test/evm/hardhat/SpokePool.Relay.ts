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
  addressToBytes,
  bytes32ToAddress,
  hashNonEmptyMessage,
  toBN,
  randomBytes32,
} from "../../../utils/utils";
import {
  spokePoolFixture,
  V3RelayData,
  V3RelayExecutionParams,
  FillStatus,
  FillType,
  getUpdatedV3DepositSignature,
  getV3RelayHash,
  getLegacyV3RelayHash,
} from "./fixtures/SpokePool.Fixture";
import {
  repaymentChainId,
  amountToSeedWallets,
  amountToDeposit,
  originChainId,
  firstDepositId,
  destinationChainId,
} from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract, erc1271: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

// _fillRelay takes a V3RelayExecutionParams object as a param. This function returns the correct object
// as a convenience.
async function getRelayExecutionParams(
  _relayData: V3RelayData,
  destinationChainId: number
): Promise<V3RelayExecutionParams> {
  return {
    relay: _relayData,
    relayHash: getV3RelayHash(_relayData, destinationChainId),
    updatedOutputAmount: _relayData.outputAmount,
    updatedRecipient: _relayData.recipient,
    updatedMessage: _relayData.message,
    repaymentChainId: repaymentChainId,
  };
}

describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20, erc1271 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, amountToDeposit);
    await weth.connect(relayer).approve(spokePool.address, amountToDeposit);
  });
  describe("fill V3", function () {
    let relayData: V3RelayData;
    beforeEach(async function () {
      const fillDeadline = (await spokePool.getCurrentTime()).toNumber() + 1000;
      relayData = {
        depositor: addressToBytes(depositor.address),
        recipient: addressToBytes(recipient.address),
        exclusiveRelayer: addressToBytes(relayer.address),
        inputToken: addressToBytes(erc20.address),
        outputToken: addressToBytes(destErc20.address),
        inputAmount: amountToDeposit,
        outputAmount: amountToDeposit,
        originChainId: originChainId,
        depositId: firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
    });
    describe("_fillRelay internal logic", function () {
      it("default status is unfilled", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Unfilled);
      });
      // @todo we can remove this after the new spoke pool is upgraded
      it("relay hash is same pre and post address -> bytes32 upgrade", async function () {
        const newBytes32Keys = ["depositor", "recipient", "exclusiveRelayer", "inputToken", "outputToken"];
        const relayDataCopy = { ...relayData, message: randomBytes32() };
        const legacyRelayData = {
          ...relayDataCopy,
          depositor: bytes32ToAddress(relayData.depositor),
          recipient: bytes32ToAddress(relayData.recipient),
          exclusiveRelayer: bytes32ToAddress(relayData.exclusiveRelayer),
          inputToken: bytes32ToAddress(relayData.inputToken),
          outputToken: bytes32ToAddress(relayData.outputToken),
        };
        expect(
          newBytes32Keys.every(
            (key) => ethers.utils.hexDataLength(legacyRelayData[key as keyof typeof legacyRelayData] as string) === 20
          )
        ).to.be.true;
        expect(
          newBytes32Keys.every(
            (key) => ethers.utils.hexDataLength(relayDataCopy[key as keyof typeof relayDataCopy] as string) === 32
          )
        ).to.be.true;
        const newRelayHash = getV3RelayHash(relayDataCopy, destinationChainId);
        const oldRelayHash = getLegacyV3RelayHash(legacyRelayData, destinationChainId);
        expect(newRelayHash).to.equal(oldRelayHash);
      });
      it("expired fill deadline reverts", async function () {
        const _relay = {
          ...relayData,
          fillDeadline: 0, // Will always be less than SpokePool.currentTime so should expire.
        };
        const relayExecution = await getRelayExecutionParams(_relay, destinationChainId);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        ).to.be.revertedWith("ExpiredFillDeadline");
      });
      it("relay hash already marked filled", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        await spokePool.setFillStatus(relayExecution.relayHash, FillStatus.Filled);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        ).to.be.revertedWith("RelayFilled");
      });
      it("fast fill replacing speed up request emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        await spokePool.setFillStatus(relayExecution.relayHash, FillStatus.RequestedSlowFill);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address),
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              addressToBytes(relayData.recipient),
              hashNonEmptyMessage(relayExecution.updatedMessage),
              relayExecution.updatedOutputAmount,
              // Testing that this FillType is not "FastFill"
              FillType.ReplacedSlowFill,
            ]
          );
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("slow fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        await destErc20.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            true // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address),
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              addressToBytes(relayData.recipient),
              hashNonEmptyMessage(relayExecution.updatedMessage),
              relayExecution.updatedOutputAmount,
              // Testing that this FillType is "SlowFill"
              FillType.SlowFill,
            ]
          );
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("fast fill emits correct FillType", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        )
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address),
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              addressToBytes(relayData.recipient),
              hashNonEmptyMessage(relayExecution.updatedMessage),
              relayExecution.updatedOutputAmount,
              FillType.FastFill,
            ]
          );
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("transfers funds even when msg.sender is recipient", async function () {
        const _relayData = {
          ...relayData,
          // Set recipient == relayer
          recipient: addressToBytes(relayer.address),
        };
        const relayExecution = await getRelayExecutionParams(_relayData, destinationChainId);
        await expect(
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        ).to.emit(destErc20, "Transfer");
      });
      it("sends updatedOutputAmount to updatedRecipient", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        const _relayExecution = {
          ...relayExecution,
          // Overwrite amount to send to be double the original amount
          updatedOutputAmount: amountToDeposit.mul(2),
          // Overwrite recipient to depositor which is not the same as the original recipient
          updatedRecipient: addressToBytes(depositor.address),
        };
        expect(_relayExecution.updatedRecipient).to.not.equal(addressToBytes(relayExecution.updatedRecipient));
        expect(_relayExecution.updatedOutputAmount).to.not.equal(relayExecution.updatedOutputAmount);
        await destErc20.connect(relayer).approve(spokePool.address, _relayExecution.updatedOutputAmount);
        await expect(() =>
          spokePool.connect(relayer).fillRelayV3Internal(
            _relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        ).to.changeTokenBalance(destErc20, depositor, amountToDeposit.mul(2));
      });
      it("unwraps native token if sending to EOA", async function () {
        const _relayData = {
          ...relayData,
          outputToken: addressToBytes(weth.address),
        };
        const relayExecution = await getRelayExecutionParams(_relayData, destinationChainId);
        await expect(() =>
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            false // isSlowFill
          )
        ).to.changeEtherBalance(recipient, relayExecution.updatedOutputAmount);
      });
      it("slow fills send native token out of spoke pool balance", async function () {
        const _relayData = {
          ...relayData,
          outputToken: addressToBytes(weth.address),
        };
        const relayExecution = await getRelayExecutionParams(_relayData, destinationChainId);
        await weth.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        const initialSpokeBalance = await weth.balanceOf(spokePool.address);
        await expect(() =>
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            true // isSlowFill
          )
        ).to.changeEtherBalance(recipient, relayExecution.updatedOutputAmount);
        const spokeBalance = await weth.balanceOf(spokePool.address);
        expect(spokeBalance).to.equal(initialSpokeBalance.sub(relayExecution.updatedOutputAmount));
      });
      it("slow fills send non-native token out of spoke pool balance", async function () {
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        await destErc20.connect(relayer).transfer(spokePool.address, relayExecution.updatedOutputAmount);
        await expect(() =>
          spokePool.connect(relayer).fillRelayV3Internal(
            relayExecution,
            addressToBytes(relayer.address),
            true // isSlowFill
          )
        ).to.changeTokenBalance(destErc20, spokePool, relayExecution.updatedOutputAmount.mul(-1));
      });
      it("if recipient is contract that implements message handler, calls message handler", async function () {
        // Does nothing if message length is 0
        const acrossMessageHandler = await createFake("AcrossMessageHandlerMock");
        const _relayData = {
          ...relayData,
          recipient: addressToBytes(acrossMessageHandler.address),
          message: "0x1234",
        };
        const relayExecution = await getRelayExecutionParams(_relayData, destinationChainId);

        // Handler is called with expected params.
        await spokePool.connect(relayer).fillRelayV3Internal(
          relayExecution,
          addressToBytes(relayer.address),
          false // isSlowFill
        );

        expect(acrossMessageHandler.handleV3AcrossMessage).to.have.been.calledOnceWith(
          bytes32ToAddress(_relayData.outputToken),
          relayExecution.updatedOutputAmount,
          relayer.address, // Custom relayer
          _relayData.message
        );
      });
    });
    describe("fillV3Relay", function () {
      it("fills are not paused", async function () {
        await spokePool.pauseFills(true);
        await expect(
          spokePool.connect(relayer).fillRelay(relayData, repaymentChainId, addressToBytes(relayer.address))
        ).to.be.revertedWith("FillsArePaused");
      });
      it("reentrancy protected", async function () {
        const functionCalldata = spokePool.interface.encodeFunctionData("fillRelay", [
          relayData,
          repaymentChainId,
          addressToBytes(relayer.address),
        ]);
        await expect(spokePool.connect(relayer).callback(functionCalldata)).to.be.revertedWith(
          "ReentrancyGuard: reentrant call"
        );
      });
      it("must be exclusive relayer before exclusivity deadline", async function () {
        const _relayData = {
          ...relayData,
          // Overwrite exclusive relayer and exclusivity deadline
          exclusiveRelayer: addressToBytes(recipient.address),
          exclusivityDeadline: relayData.fillDeadline,
        };
        await expect(
          spokePool.connect(relayer).fillRelay(_relayData, repaymentChainId, addressToBytes(relayer.address))
        ).to.be.revertedWith("NotExclusiveRelayer");

        // Can send it after exclusivity deadline
        await expect(
          spokePool
            .connect(relayer)
            .fillRelay({ ..._relayData, exclusivityDeadline: 0 }, repaymentChainId, addressToBytes(relayer.address))
        ).to.not.be.reverted;
      });
      it("calls _fillRelayV3 with expected params", async function () {
        await expect(spokePool.connect(relayer).fillRelay(relayData, repaymentChainId, addressToBytes(relayer.address)))
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            repaymentChainId, // Should be passed-in repayment chain ID
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address), // Should be equal to msg.sender of fillRelayV3
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              addressToBytes(relayData.recipient), // updatedRecipient should be equal to recipient
              hashNonEmptyMessage(relayData.message), // updatedMessageHash should be equal to message hash
              relayData.outputAmount, // updatedOutputAmount should be equal to outputAmount
              // Should be FastFill
              FillType.FastFill,
            ]
          );
      });
      it("calls legacy (address) fillRelayV3 with expected params", async function () {
        const legacyRelayData = {
          ...relayData,
          depositor: bytes32ToAddress(relayData.depositor),
          recipient: bytes32ToAddress(relayData.recipient),
          exclusiveRelayer: bytes32ToAddress(relayData.exclusiveRelayer),
          inputToken: bytes32ToAddress(relayData.inputToken),
          outputToken: bytes32ToAddress(relayData.outputToken),
        };
        await expect(spokePool.connect(relayer).fillV3Relay(legacyRelayData, repaymentChainId))
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            repaymentChainId, // Should be passed-in repayment chain ID
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address), // Should be equal to msg.sender of fillRelayV3
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              addressToBytes(relayData.recipient), // updatedRecipient should be equal to recipient
              hashNonEmptyMessage(relayData.message), // updatedMessageHash should be equal to message hash
              relayData.outputAmount, // updatedOutputAmount should be equal to outputAmount
              // Should be FastFill
              FillType.FastFill,
            ]
          );
      });
    });
    describe("fillRelayWithUpdatedDeposit", function () {
      let updatedOutputAmount: BigNumber, updatedRecipient: string, updatedMessage: string, signature: string;
      beforeEach(async function () {
        updatedOutputAmount = relayData.outputAmount.add(1);
        updatedRecipient = randomAddress();
        updatedMessage = createRandomBytes32();
        relayData.originChainId = await spokePool.chainId(); // Use spoke pool chain ID so that
        // we can call speedUpDeposit and fillRelayWithUpdatedDeposit on the same
        // spoke pool and verify the same signature.
        await destErc20.connect(relayer).approve(spokePool.address, updatedOutputAmount);
        signature = await getUpdatedV3DepositSignature(
          depositor,
          relayData.depositId,
          relayData.originChainId,
          updatedOutputAmount,
          addressToBytes(updatedRecipient),
          updatedMessage
        );
      });
      it("Verifies same signature as speedUpDeposit", async function () {
        // Both fillRelayWithUpdatedDeposit and speedUpDeposit use the same signature, meaning that they both
        // verify the signature using the same internal logic. None of the following
        // calls should revert
        await spokePool
          .connect(relayer)
          .fillRelayWithUpdatedDeposit(
            relayData,
            repaymentChainId,
            addressToBytes(relayer.address),
            updatedOutputAmount,
            addressToBytes(updatedRecipient),
            updatedMessage,
            signature
          );
        await spokePool
          .connect(depositor)
          .speedUpV3Deposit(
            depositor.address,
            relayData.depositId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            signature
          );
        await spokePool
          .connect(depositor)
          .speedUpDeposit(
            addressToBytes(depositor.address),
            relayData.depositId,
            updatedOutputAmount,
            addressToBytes(updatedRecipient),
            updatedMessage,
            signature
          );
      });
      it("in absence of exclusivity", async function () {
        // Clock drift between spokes can mean exclusivityDeadline is in future even when no exclusivity was applied.
        await spokePool.setCurrentTime(relayData.exclusivityDeadline - 1);
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, exclusivityDeadline: 0 },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.emit(spokePool, "FilledRelay");
      });
      it("must be exclusive relayer before exclusivity deadline", async function () {
        const _relayData = {
          ...relayData,
          // Overwrite exclusive relayer and exclusivity deadline
          exclusiveRelayer: addressToBytes(recipient.address),
          exclusivityDeadline: relayData.fillDeadline,
        };
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              _relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("NotExclusiveRelayer");

        // Even if not exclusive relayer, can send it after exclusivity deadline
        await expect(
          spokePool.connect(relayer).fillRelayWithUpdatedDeposit(
            {
              ..._relayData,
              exclusivityDeadline: 0,
            },
            repaymentChainId,
            addressToBytes(relayer.address),
            updatedOutputAmount,
            addressToBytes(updatedRecipient),
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
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        )
          .to.emit(spokePool, "FilledRelay")
          .withArgs(
            addressToBytes(relayData.inputToken),
            addressToBytes(relayData.outputToken),
            relayData.inputAmount,
            relayData.outputAmount,
            repaymentChainId, // Should be passed-in repayment chain ID
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            addressToBytes(relayData.exclusiveRelayer),
            addressToBytes(relayer.address), // Should be equal to msg.sender
            addressToBytes(relayData.depositor),
            addressToBytes(relayData.recipient),
            hashNonEmptyMessage(relayData.message),
            [
              // Should use passed-in updated params:
              addressToBytes(updatedRecipient),
              hashNonEmptyMessage(updatedMessage),
              updatedOutputAmount,
              // Should be FastFill
              FillType.FastFill,
            ]
          );

        // Check fill status mapping is updated
        const relayExecution = await getRelayExecutionParams(relayData, destinationChainId);
        expect(await spokePool.fillStatuses(relayExecution.relayHash)).to.equal(FillStatus.Filled);
      });
      it("validates depositor signature", async function () {
        // Incorrect depositor
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, depositor: addressToBytes(relayer.address) },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect signature for new deposit ID
        const otherSignature = await getUpdatedV3DepositSignature(
          depositor,
          relayData.depositId.add(toBN(1)),
          relayData.originChainId,
          updatedOutputAmount,
          addressToBytes(updatedRecipient),
          updatedMessage
        );
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              otherSignature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect origin chain ID
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, originChainId: relayData.originChainId + 1 },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect deposit ID
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, depositId: relayData.depositId.add(toBN(1)) },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect updated output amount
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount.sub(1),
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect updated recipient
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(randomAddress()),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");

        // Incorrect updated message
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              createRandomBytes32()
            )
        ).to.be.revertedWith("InvalidDepositorSignature");
      });
      it("validates ERC-1271 depositor contract signature", async function () {
        // The MockERC1271 contract returns true for isValidSignature if the signature was signed by the contract's
        // owner, so using the depositor's signature should succeed and using someone else's signature should fail.
        const incorrectSignature = await getUpdatedV3DepositSignature(
          relayer, // not depositor
          relayData.depositId,
          relayData.originChainId,
          updatedOutputAmount,
          addressToBytes(updatedRecipient),
          updatedMessage
        );
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, depositor: addressToBytes(erc1271.address) },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              incorrectSignature
            )
        ).to.be.revertedWith("InvalidDepositorSignature");
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              { ...relayData, depositor: addressToBytes(erc1271.address) },
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.not.be.reverted;
      });
      it("cannot send updated fill after original fill", async function () {
        await spokePool.connect(relayer).fillRelay(relayData, repaymentChainId, addressToBytes(relayer.address));
        await expect(
          spokePool
            .connect(relayer)
            .fillRelayWithUpdatedDeposit(
              relayData,
              repaymentChainId,
              addressToBytes(relayer.address),
              updatedOutputAmount,
              addressToBytes(updatedRecipient),
              updatedMessage,
              signature
            )
        ).to.be.revertedWith("RelayFilled");
      });
      it("cannot send updated fill after slow fill", async function () {
        await spokePool
          .connect(relayer)
          .fillRelayWithUpdatedDeposit(
            relayData,
            repaymentChainId,
            addressToBytes(relayer.address),
            updatedOutputAmount,
            addressToBytes(updatedRecipient),
            updatedMessage,
            signature
          );
        await expect(
          spokePool.connect(relayer).fillRelay(relayData, repaymentChainId, addressToBytes(relayer.address))
        ).to.be.revertedWith("RelayFilled");
      });
    });
  });
});
