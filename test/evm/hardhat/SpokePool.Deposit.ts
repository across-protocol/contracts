import {
  expect,
  ethers,
  Contract,
  SignerWithAddress,
  seedWallet,
  toBN,
  toWei,
  randomAddress,
  BigNumber,
} from "../../../utils/utils";
import {
  spokePoolFixture,
  enableRoutes,
  getDepositParams,
  V3RelayData,
  getUpdatedV3DepositSignature,
} from "./fixtures/SpokePool.Fixture";
import {
  amountToSeedWallets,
  amountToDeposit,
  destinationChainId,
  depositRelayerFeePct,
  realizedLpFeePct,
  amountReceived,
  MAX_UINT32,
  originChainId,
  MAX_EXCLUSIVITY_OFFSET_SECONDS,
  zeroAddress,
} from "./constants";

const { AddressZero: ZERO_ADDRESS } = ethers.constants;

describe("SpokePool Depositor Logic", async function () {
  let spokePool: Contract, weth: Contract, erc20: Contract, unwhitelistedErc20: Contract;
  let depositor: SignerWithAddress, recipient: SignerWithAddress;
  let quoteTimestamp: number;
  let amount = amountToDeposit;
  const relayerFeePct = toBN(depositRelayerFeePct).add(realizedLpFeePct);

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

    quoteTimestamp = (await spokePool.getCurrentTime()).toNumber();
  });

  it("Depositing ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const revertReason = "DepositsArePaused";

    // Can't deposit when paused:
    await spokePool.connect(depositor).pauseDeposits(true);
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount: amountToDeposit,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.be.revertedWith(revertReason);

    await spokePool.connect(depositor).pauseDeposits(false);

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          recipient: recipient.address,
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    )
      .to.emit(spokePool, "V3FundsDeposited")
      .withArgs(
        erc20.address,
        ZERO_ADDRESS,
        amountToDeposit,
        amountReceived,
        destinationChainId,
        0,
        quoteTimestamp,
        MAX_UINT32,
        0,
        depositor.address,
        recipient.address,
        ZERO_ADDRESS,
        "0x"
      );

    // The collateral should have transferred from depositor to contract.
    expect(await erc20.balanceOf(depositor.address)).to.equal(amountToSeedWallets.sub(amountToDeposit));
    expect(await erc20.balanceOf(spokePool.address)).to.equal(amountToDeposit);

    // Deposit nonce should increment.
    expect(await spokePool.numberOfDeposits()).to.equal(1);
  });

  it("DepositFor overrrides the depositor", async function () {
    const newDepositor = randomAddress();
    await expect(
      spokePool.connect(depositor).depositFor(
        newDepositor,
        ...getDepositParams({
          recipient: recipient.address,
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    )
      .to.emit(spokePool, "V3FundsDeposited")
      .withArgs(
        erc20.address,
        ZERO_ADDRESS,
        amountToDeposit,
        amountReceived,
        destinationChainId,
        0,
        quoteTimestamp,
        BigNumber.from("0xFFFFFFFF"),
        0,
        newDepositor, // Depositor is overridden.
        recipient.address,
        ZERO_ADDRESS,
        "0x"
      );
  });
  it("Depositing ETH correctly wraps into WETH", async function () {
    const revertReason = "MsgValueDoesNotMatchInputAmount";

    // Fails if msg.value > 0 but doesn't match amount to deposit.
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: weth.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        }),
        { value: 1 }
      )
    ).to.be.revertedWith(revertReason);

    await expect(() =>
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          recipient: recipient.address,
          originToken: weth.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        }),
        { value: amountToDeposit }
      )
    ).to.changeEtherBalances([depositor, weth], [amountToDeposit.mul(toBN("-1")), amountToDeposit]); // ETH should transfer from depositor to WETH contract.

    // WETH balance for user should be same as start, but WETH balancein pool should increase.
    expect(await weth.balanceOf(depositor.address)).to.equal(amountToSeedWallets);
    expect(await weth.balanceOf(spokePool.address)).to.equal(amountToDeposit);
  });

  it("Depositing ETH with msg.value = 0 pulls WETH from depositor", async function () {
    await expect(() =>
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: weth.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        }),
        { value: 0 }
      )
    ).to.changeTokenBalances(weth, [depositor, spokePool], [amountToDeposit.mul(toBN("-1")), amountToDeposit]);
  });

  it("SpokePool is not approved to spend originToken", async function () {
    const insufficientAllowance = "ERC20: insufficient allowance";

    await erc20.connect(depositor).approve(spokePool.address, 0);
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.be.revertedWith(insufficientAllowance);

    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.emit(spokePool, "V3FundsDeposited");
  });

  it("Deposit route is disabled", async function () {
    const revertReason = "DisabledRoute";

    // Verify that routes are disabled by default.
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: unwhitelistedErc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.be.revertedWith(revertReason);

    // Verify that the route is enabled.
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.emit(spokePool, "V3FundsDeposited");

    // Disable the route.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, destinationChainId, false);
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.be.revertedWith(revertReason);

    // Re-enable the route and verify that it works again.
    await spokePool.connect(depositor).setEnableRoute(erc20.address, destinationChainId, true);
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp,
        })
      )
    ).to.emit(spokePool, "V3FundsDeposited");
  });

  it("Relayer fee is invalid", async function () {
    const revertReason = "InvalidRelayerFee";

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct: toWei("1"), // Fee > 50%
          quoteTimestamp,
        })
      )
    ).to.be.revertedWith(revertReason);
  });

  it("quoteTimestamp is out of range", async function () {
    const revertReason = "InvalidQuoteTimestamp";
    const quoteTimeBuffer = await spokePool.depositQuoteTimeBuffer();

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp: quoteTimestamp + 1,
        })
      )
    ).to.be.revertedWith("underflowed");

    await expect(
      spokePool.connect(depositor).deposit(
        ...getDepositParams({
          originToken: erc20.address,
          amount,
          destinationChainId,
          relayerFeePct,
          quoteTimestamp: quoteTimestamp - (quoteTimeBuffer + 1),
        })
      )
    ).to.be.revertedWith(revertReason);

    // quoteTimestamp at the exact margins should succeed.
    for (const offset of [0, quoteTimeBuffer]) {
      await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
      await expect(
        spokePool.connect(depositor).deposit(
          ...getDepositParams({
            originToken: erc20.address,
            amount,
            destinationChainId,
            relayerFeePct,
            quoteTimestamp: quoteTimestamp - offset,
          })
        )
      ).to.emit(spokePool, "V3FundsDeposited");
    }
  });

  describe("deposit V3", function () {
    let relayData: V3RelayData, depositArgs: any[];
    function getDepositArgsFromRelayData(
      _relayData: V3RelayData,
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
      await spokePool.connect(depositor).depositV3(...depositArgs);
    });
    it("route disabled", async function () {
      // Verify that routes are disabled by default for a new route
      const _depositArgs = getDepositArgsFromRelayData(relayData, 999);
      await expect(spokePool.connect(depositor).depositV3(..._depositArgs)).to.be.revertedWith("DisabledRoute");

      // Enable the route:
      await spokePool.connect(depositor).setEnableRoute(erc20.address, 999, true);
      await expect(spokePool.connect(depositor).depositV3(..._depositArgs)).to.not.be.reverted;
    });
    it("invalid quoteTimestamp", async function () {
      const quoteTimeBuffer = await spokePool.depositQuoteTimeBuffer();
      const currentTime = await spokePool.getCurrentTime();

      await expect(
        spokePool.connect(depositor).depositV3(
          // quoteTimestamp too far into past (i.e. beyond the buffer)
          ...getDepositArgsFromRelayData(relayData, destinationChainId, currentTime.sub(quoteTimeBuffer).sub(1))
        )
      ).to.be.revertedWith("InvalidQuoteTimestamp");
      await expect(
        spokePool.connect(depositor).depositV3(
          // quoteTimestamp right at the buffer is OK
          ...getDepositArgsFromRelayData(relayData, destinationChainId, currentTime.sub(quoteTimeBuffer))
        )
      ).to.not.be.reverted;
    });
    it("invalid fillDeadline", async function () {
      const fillDeadlineBuffer = await spokePool.fillDeadlineBuffer();
      const currentTime = await spokePool.getCurrentTime();

      await expect(
        spokePool.connect(depositor).depositV3(
          // fillDeadline too far into future (i.e. beyond the buffer)
          ...getDepositArgsFromRelayData({ ...relayData, fillDeadline: currentTime.add(fillDeadlineBuffer).add(1) })
        )
      ).to.be.revertedWith("InvalidFillDeadline");
      await expect(
        spokePool.connect(depositor).depositV3(
          // fillDeadline in past
          ...getDepositArgsFromRelayData({ ...relayData, fillDeadline: currentTime.sub(1) })
        )
      ).to.be.revertedWith("InvalidFillDeadline");
      await expect(
        spokePool.connect(depositor).depositV3(
          // fillDeadline right at the buffer is OK
          ...getDepositArgsFromRelayData({ ...relayData, fillDeadline: currentTime.add(fillDeadlineBuffer) })
        )
      ).to.not.be.reverted;
    });
    it("invalid exclusivity params", async function () {
      const currentTime = await spokePool.getCurrentTime();

      // If exclusive deadline is not zero, then exclusive relayer must be set.
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: 1,
          })
        )
      ).to.be.revertedWith("InvalidExclusiveRelayer");
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: MAX_EXCLUSIVITY_OFFSET_SECONDS,
          })
        )
      ).to.be.revertedWith("InvalidExclusiveRelayer");
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: MAX_EXCLUSIVITY_OFFSET_SECONDS + 1,
          })
        )
      ).to.be.revertedWith("InvalidExclusiveRelayer");
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: currentTime.sub(1),
          })
        )
      ).to.be.revertedWith("InvalidExclusiveRelayer");
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: currentTime.add(1),
          })
        )
      ).to.be.revertedWith("InvalidExclusiveRelayer");
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData({
            ...relayData,
            exclusiveRelayer: zeroAddress,
            exclusivityDeadline: 0,
          })
        )
      ).to.not.be.reverted;
    });
    it("exclusivity param is used as an offset", async function () {
      const currentTime = (await spokePool.getCurrentTime()).toNumber();
      const fillDeadlineOffset = 1000;
      const exclusivityDeadlineOffset = MAX_EXCLUSIVITY_OFFSET_SECONDS;
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData(
            {
              ...relayData,
              exclusiveRelayer: depositor.address,
              exclusivityDeadline: exclusivityDeadlineOffset,
            },
            undefined,
            currentTime
          )
        )
      )
        .to.emit(spokePool, "V3FundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          // deposit ID is 0 for first deposit
          0,
          currentTime, // quoteTimestamp should be current time
          currentTime + fillDeadlineOffset, // fillDeadline should be current time + offset
          currentTime + exclusivityDeadlineOffset, // exclusivityDeadline should be current time + offset
          relayData.depositor,
          relayData.recipient,
          depositor.address,
          relayData.message
        );
    });
    it("exclusivity param is used as a timestamp", async function () {
      const currentTime = (await spokePool.getCurrentTime()).toNumber();
      const fillDeadlineOffset = 1000;
      const exclusivityDeadlineTimestamp = MAX_EXCLUSIVITY_OFFSET_SECONDS + 1;
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData(
            {
              ...relayData,
              exclusiveRelayer: depositor.address,
              exclusivityDeadline: exclusivityDeadlineTimestamp,
            },
            undefined,
            currentTime
          )
        )
      )
        .to.emit(spokePool, "V3FundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          // deposit ID is 0 for first deposit
          0,
          currentTime, // quoteTimestamp should be current time
          currentTime + fillDeadlineOffset, // fillDeadline should be current time + offset
          exclusivityDeadlineTimestamp, // exclusivityDeadline should be passed in time
          relayData.depositor,
          relayData.recipient,
          depositor.address,
          relayData.message
        );
    });
    it("exclusivity param is set to 0", async function () {
      const currentTime = (await spokePool.getCurrentTime()).toNumber();
      const fillDeadlineOffset = 1000;
      const zeroExclusivity = 0;
      await expect(
        spokePool.connect(depositor).depositV3(
          ...getDepositArgsFromRelayData(
            {
              ...relayData,
              exclusiveRelayer: depositor.address,
              exclusivityDeadline: zeroExclusivity,
            },
            undefined,
            currentTime
          )
        )
      )
        .to.emit(spokePool, "V3FundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          // deposit ID is 0 for first deposit
          0,
          currentTime, // quoteTimestamp should be current time
          currentTime + fillDeadlineOffset, // fillDeadline should be current time + offset
          0, // Exclusivity deadline should always be 0
          relayData.depositor,
          relayData.recipient,
          depositor.address,
          relayData.message
        );
    });
    it("if input token is WETH and msg.value > 0, msg.value must match inputAmount", async function () {
      await expect(
        spokePool
          .connect(depositor)
          .depositV3(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), { value: 1 })
      ).to.be.revertedWith("MsgValueDoesNotMatchInputAmount");

      // Pulls ETH from depositor and deposits it into WETH via the wrapped contract.
      await expect(() =>
        spokePool
          .connect(depositor)
          .depositV3(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), {
            value: amountToDeposit,
          })
      ).to.changeEtherBalances([depositor, weth], [amountToDeposit.mul(toBN("-1")), amountToDeposit]); // ETH should transfer from depositor to WETH contract.

      // WETH balance for user should be same as start, but WETH balance in pool should increase.
      expect(await weth.balanceOf(spokePool.address)).to.equal(amountToDeposit);
    });
    it("if input token is not WETH then msg.value must be 0", async function () {
      await expect(
        spokePool.connect(depositor).depositV3(...getDepositArgsFromRelayData(relayData), { value: 1 })
      ).to.be.revertedWith("MsgValueDoesNotMatchInputAmount");
    });
    it("if input token is WETH and msg.value = 0, pulls ERC20 from depositor", async function () {
      await expect(() =>
        spokePool
          .connect(depositor)
          .depositV3(...getDepositArgsFromRelayData({ ...relayData, inputToken: weth.address }), { value: 0 })
      ).to.changeTokenBalances(weth, [depositor, spokePool], [amountToDeposit.mul(toBN("-1")), amountToDeposit]);
    });
    it("pulls input token from caller", async function () {
      await expect(() => spokePool.connect(depositor).depositV3(...depositArgs)).to.changeTokenBalances(
        erc20,
        [depositor, spokePool],
        [amountToDeposit.mul(toBN("-1")), amountToDeposit]
      );
    });
    it("depositV3Now uses current time as quote time", async function () {
      const currentTime = (await spokePool.getCurrentTime()).toNumber();
      const fillDeadlineOffset = 1000;
      const exclusivityDeadline = 0;
      await expect(
        spokePool
          .connect(depositor)
          .depositV3Now(
            relayData.depositor,
            relayData.recipient,
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            destinationChainId,
            relayData.exclusiveRelayer,
            fillDeadlineOffset,
            exclusivityDeadline,
            relayData.message
          )
      )
        .to.emit(spokePool, "V3FundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          // deposit ID is 0 for first deposit
          0,
          currentTime, // quoteTimestamp should be current time
          currentTime + fillDeadlineOffset, // fillDeadline should be current time + offset
          0,
          relayData.depositor,
          relayData.recipient,
          relayData.exclusiveRelayer,
          relayData.message
        );
    });
    it("emits V3FundsDeposited event with correct deposit ID", async function () {
      await expect(spokePool.connect(depositor).depositV3(...depositArgs))
        .to.emit(spokePool, "V3FundsDeposited")
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
          0,
          relayData.depositor,
          relayData.recipient,
          relayData.exclusiveRelayer,
          relayData.message
        );
    });
    it("deposit ID state variable incremented", async function () {
      await spokePool.connect(depositor).depositV3(...depositArgs);
      expect(await spokePool.numberOfDeposits()).to.equal(1);
    });
    it("tokens are always pulled from caller, even if different from specified depositor", async function () {
      const balanceBefore = await erc20.balanceOf(depositor.address);
      const newDepositor = randomAddress();
      await expect(
        spokePool
          .connect(depositor)
          .depositV3(...getDepositArgsFromRelayData({ ...relayData, depositor: newDepositor }))
      )
        .to.emit(spokePool, "V3FundsDeposited")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          destinationChainId,
          0,
          quoteTimestamp,
          relayData.fillDeadline,
          0,
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
      await expect(spokePool.connect(depositor).depositV3(...depositArgs)).to.be.revertedWith("DepositsArePaused");
    });
    it("reentrancy protected", async function () {
      const functionCalldata = spokePool.interface.encodeFunctionData("depositV3", [...depositArgs]);
      await expect(spokePool.connect(depositor).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
  });
  describe("speed up V3 deposit", function () {
    const updatedOutputAmount = amountToDeposit.add(1);
    const updatedRecipient = randomAddress();
    const updatedMessage = "0x1234";
    const depositId = 100;
    it("_verifyUpdateV3DepositMessage", async function () {
      const signature = await getUpdatedV3DepositSignature(
        depositor,
        depositId,
        originChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await spokePool.verifyUpdateV3DepositMessage(
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
        spokePool.verifyUpdateV3DepositMessage(
          updatedRecipient,
          depositId,
          originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          signature
        )
      ).to.be.revertedWith("InvalidDepositorSignature");

      // @dev Creates an invalid signature using different params
      const invalidSignature = await getUpdatedV3DepositSignature(
        depositor,
        depositId + 1,
        originChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.verifyUpdateV3DepositMessage(
          depositor.address,
          depositId,
          originChainId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          invalidSignature
        )
      ).to.be.revertedWith("InvalidDepositorSignature");
    });
    it("passes spoke pool's chainId() as origin chainId", async function () {
      const spokePoolChainId = await spokePool.chainId();

      const expectedSignature = await getUpdatedV3DepositSignature(
        depositor,
        depositId,
        spokePoolChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.speedUpV3Deposit(
          depositor.address,
          depositId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          expectedSignature
        )
      )
        .to.emit(spokePool, "RequestedSpeedUpV3Deposit")
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
      const invalidSignatureForChain = await getUpdatedV3DepositSignature(
        depositor,
        depositId,
        otherChainId,
        updatedOutputAmount,
        updatedRecipient,
        updatedMessage
      );
      await expect(
        spokePool.verifyUpdateV3DepositMessage(
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
        spokePool.speedUpV3Deposit(
          depositor.address,
          depositId,
          updatedOutputAmount,
          updatedRecipient,
          updatedMessage,
          invalidSignatureForChain
        )
      ).to.be.revertedWith("InvalidDepositorSignature");
    });
  });
});
