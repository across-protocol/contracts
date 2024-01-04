import { expect, ethers, Contract, SignerWithAddress, seedWallet, toBN, randomAddress } from "../utils/utils";
import {
  spokePoolFixture,
  enableRoutes,
  USSRelayData,
  getUpdatedUSSDepositSignature,
} from "./fixtures/SpokePool.Fixture";
import { amountToSeedWallets, amountToDeposit, destinationChainId, originChainId } from "./constants";

const { AddressZero: ZERO_ADDRESS } = ethers.constants;

describe("SpokePool Depositor Logic", async function () {
  let spokePool: Contract, weth: Contract, erc20: Contract;
  let depositor: SignerWithAddress, recipient: SignerWithAddress;
  let quoteTimestamp: number;

  beforeEach(async function () {
    [depositor, recipient] = await ethers.getSigners();
    ({ weth, erc20, spokePool } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for the depositor.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);

    quoteTimestamp = (await spokePool.getCurrentTime()).toNumber();
  });

  describe("deposit USS", function () {
    let relayData: USSRelayData, depositArgs: any[];
    function getDepositArgsFromRelayData(
      _relayData: USSRelayData,
      _destinationChainId = destinationChainId,
      _quoteTimestamp = quoteTimestamp
    ) {
      return [
        _relayData.depositor,
        _relayData.recipient,
        _relayData.inputToken,
        _relayData.outputToken,
        _relayData.inputAmount,
        _relayData.outputAmount,
        _destinationChainId,
        _relayData.exclusiveRelayer,
        _quoteTimestamp,
        _relayData.fillDeadline,
        _relayData.exclusivityDeadline,
        _relayData.message,
      ];
    }
    beforeEach(async function () {
      relayData = {
        depositor: depositor.address,
        recipient: recipient.address,
        exclusiveRelayer: ZERO_ADDRESS,
        inputToken: erc20.address,
        outputToken: randomAddress(),
        inputAmount: amountToDeposit,
        outputAmount: amountToDeposit.sub(19),
        originChainId: originChainId,
        depositId: 0,
        fillDeadline: quoteTimestamp + 1000,
        exclusivityDeadline: 0,
        message: "0x",
      };
      depositArgs = getDepositArgsFromRelayData(relayData);
    });
    it("placeholder: gas test", async function () {
      await spokePool.connect(depositor).depositUSS(...depositArgs);
    });
    it("route disabled", async function () {
      // Verify that routes are disabled by default for a new route
      const _depositArgs = getDepositArgsFromRelayData(relayData, 999);
      await expect(spokePool.connect(depositor).depositUSS(..._depositArgs)).to.be.revertedWith("DisabledRoute");

      // Enable the route:
      await spokePool.connect(depositor).setEnableRoute(erc20.address, 999, true);
      await expect(spokePool.connect(depositor).depositUSS(..._depositArgs)).to.not.be.reverted;
    });
    it("invalid quoteTimestamp", async function () {
      const quoteTimeBuffer = await spokePool.depositQuoteTimeBuffer();
      const currentTime = await spokePool.getCurrentTime();

      await expect(
        spokePool.connect(depositor).depositUSS(
          // quoteTimestamp too far into past (i.e. beyond the buffer)
          ...getDepositArgsFromRelayData(relayData, destinationChainId, currentTime.sub(quoteTimeBuffer).sub(1))
        )
      ).to.be.revertedWith("InvalidQuoteTimestamp");
      await expect(
        spokePool.connect(depositor).depositUSS(
          // quoteTimestamp right at the buffer is OK
          ...getDepositArgsFromRelayData(relayData, destinationChainId, currentTime.sub(quoteTimeBuffer))
        )
      ).to.not.be.reverted;
    });
    it("invalid fillDeadline", async function () {
      const fillDeadlineBuffer = await spokePool.fillDeadlineBuffer();
      const currentTime = await spokePool.getCurrentTime();

      await expect(
        spokePool.connect(depositor).depositUSS(
          // fillDeadline too far into future (i.e. beyond the buffer)
          ...getDepositArgsFromRelayData({ ...relayData, fillDeadline: currentTime.add(fillDeadlineBuffer).add(1) })
        )
      ).to.be.revertedWith("InvalidFillDeadline");
      await expect(
        spokePool.connect(depositor).depositUSS(
          // fillDeadline right at the buffer is OK
          ...getDepositArgsFromRelayData({ ...relayData, fillDeadline: currentTime.add(fillDeadlineBuffer) })
        )
      ).to.not.be.reverted;
    });
    it("if input token is WETH and msg.value > 0, msg.value must match inputAmount", async function () {
      await expect(
        spokePool
          .connect(depositor)
          .depositUSS(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), { value: 1 })
      ).to.be.revertedWith("MsgValueDoesNotMatchInputAmount");

      // Pulls ETH from depositor and deposits it into WETH via the wrapped contract.
      await expect(() =>
        spokePool
          .connect(depositor)
          .depositUSS(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), {
            value: amountToDeposit,
          })
      ).to.changeEtherBalances([depositor, weth], [amountToDeposit.mul(toBN("-1")), amountToDeposit]); // ETH should transfer from depositor to WETH contract.

      // WETH balance for user should be same as start, but WETH balance in pool should increase.
      expect(await weth.balanceOf(spokePool.address)).to.equal(amountToDeposit);
    });
    it("if input token is WETH and msg.value = 0, pulls ERC20 from depositor", async function () {
      await expect(() =>
        spokePool
          .connect(depositor)
          .depositUSS(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), { value: 0 })
      ).to.changeTokenBalances(weth, [depositor, spokePool], [amountToDeposit.mul(toBN("-1")), amountToDeposit]);
    });
    it("pulls input token from caller", async function () {
      await expect(() => spokePool.connect(depositor).depositUSS(...depositArgs)).to.changeTokenBalances(
        erc20,
        [depositor, spokePool],
        [amountToDeposit.mul(toBN("-1")), amountToDeposit]
      );
    });
    it("emits USSFundsDeposited event with correct deposit ID", async function () {
      await expect(spokePool.connect(depositor).depositUSS(...depositArgs))
        .to.emit(spokePool, "USSFundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          // deposit ID is 0 for first deposit
          0,
          quoteTimestamp,
          relayData.fillDeadline,
          relayData.exclusivityDeadline,
          relayData.depositor,
          relayData.recipient,
          relayData.exclusiveRelayer,
          relayData.message
        );
    });
    it("deposit ID state variable incremented", async function () {
      await spokePool.connect(depositor).depositUSS(...depositArgs);
      expect(await spokePool.numberOfDeposits()).to.equal(1);
    });
    it("tokens are always pulled from caller, even if different from specified depositor", async function () {
      const balanceBefore = await erc20.balanceOf(depositor.address);
      const newDepositor = randomAddress();
      await expect(
        spokePool
          .connect(depositor)
          .depositUSS(...getDepositArgsFromRelayData({ ...relayData, depositor: newDepositor }))
      )
        .to.emit(spokePool, "USSFundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          0,
          quoteTimestamp,
          relayData.fillDeadline,
          relayData.exclusivityDeadline,
          // New depositor
          newDepositor,
          relayData.recipient,
          relayData.exclusiveRelayer,
          relayData.message
        );
      expect(await erc20.balanceOf(depositor.address)).to.equal(balanceBefore.sub(amountToDeposit));
    });
    it("deposits are not paused", async function () {
      await spokePool.pauseDeposits(true);
      await expect(spokePool.connect(depositor).depositUSS(...depositArgs)).to.be.revertedWith("Paused deposits");
    });
    it("reentrancy protected", async function () {
      const functionCalldata = spokePool.interface.encodeFunctionData("depositUSS", [...depositArgs]);
      await expect(spokePool.connect(depositor).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
  });
  describe("speed up USS deposit", function () {
    const updatedOutputAmount = amountToDeposit.add(1);
    const updatedRecipient = randomAddress();
    const updatedMessage = "0x1234";
    const depositId = 100;
    it("_verifyUpdateUSSDepositMessage", async function () {
      const signature = await getUpdatedUSSDepositSignature(
        depositor,
        depositId,
        originChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await spokePool.verifyUpdateUSSDepositMessage(
        depositor.address,
        depositId,
        originChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage,
        signature
      );

      // Reverts if passed in depositor is the signer or if signature is incorrect
      await expect(
        spokePool.verifyUpdateUSSDepositMessage(
          updatedRecipient,
          depositId,
          originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          signature
        )
      ).to.be.revertedWith("invalid signature");

      // @dev Creates an invalid signature using different params
      const invalidSignature = await getUpdatedUSSDepositSignature(
        depositor,
        depositId + 1,
        originChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.verifyUpdateUSSDepositMessage(
          depositor.address,
          depositId,
          originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          invalidSignature
        )
      ).to.be.revertedWith("invalid signature");
    });
    it("passes spoke pool's chainId() as origin chainId", async function () {
      const spokePoolChainId = await spokePool.chainId();

      const expectedSignature = await getUpdatedUSSDepositSignature(
        depositor,
        depositId,
        spokePoolChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.speedUpUSSDeposit(
          depositor.address,
          depositId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          expectedSignature
        )
      )
        .to.emit(spokePool, "RequestedSpeedUpUSSDeposit")
        .withArgs(
          updatedOutputAmount,
          depositId,
          depositor.address,
          updatedRecipient,
          updatedMessage,
          expectedSignature
        );

      // Can't use a signature for a different chain ID, even if the signature is valid otherwise for the depositor.
      const otherChainId = spokePoolChainId.add(1);
      const invalidSignatureForChain = await getUpdatedUSSDepositSignature(
        depositor,
        depositId,
        otherChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.verifyUpdateUSSDepositMessage(
          depositor.address,
          depositId,
          otherChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          invalidSignatureForChain
        )
      ).to.not.be.reverted;
      await expect(
        spokePool.speedUpUSSDeposit(
          depositor.address,
          depositId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          invalidSignatureForChain
        )
      ).to.be.revertedWith("invalid signature");
    });
  });
});
