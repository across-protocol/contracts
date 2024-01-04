import {
  expect,
  Contract,
  ethers,
  SignerWithAddress,
  seedWallet,
  toBN,
  randomAddress,
  randomBigNumber,
  BigNumber,
  toWei,
} from "../utils/utils";
import {
  spokePoolFixture,
  enableRoutes,
  getExecuteSlowRelayParams,
  SlowFill,
  getUSSRelayHash,
  USSSlowFill,
} from "./fixtures/SpokePool.Fixture";
import { getFillRelayParams, getRelayHash } from "./fixtures/SpokePool.Fixture";
import { MerkleTree } from "../utils/MerkleTree";
import { buildSlowRelayTree, buildUSSSlowRelayTree } from "./MerkleLib.utils";
import * as consts from "./constants";
import { FillStatus } from "../utils/constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;
let slowFills: SlowFill[];
let tree: MerkleTree<SlowFill>;

const OTHER_DESTINATION_CHAIN_ID = (consts.destinationChainId + 666).toString();
const ZERO = BigNumber.from(0);

// Random message for ERC20 case.
const erc20Message = randomBigNumber(100).toHexString();

// Random message for WETH case.
const wethMessage = randomBigNumber(100).toHexString();

// Relay fees for slow relay are only the realizedLpFee; the depositor should be re-funded the relayer fee
// for any amount sent by a slow relay.
const fullRelayAmountPostFees = consts.amountToRelay
  .mul(toBN(consts.oneHundredPct).sub(consts.realizedLpFeePct))
  .div(toBN(consts.oneHundredPct));

describe("SpokePool Slow Relay Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(depositor, [destErc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, consts.amountToSeedWallets);

    // Send tokens to the spoke pool for repayment.
    await destErc20.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees.mul(10));
    await weth.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees.div(2));

    // Approve spoke pool to take relayer's tokens.
    await destErc20.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);
    await weth.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);

    slowFills = [];
    for (let i = 0; i < 99; i++) {
      // Relay for different destination chain
      slowFills.push({
        relayData: {
          depositor: randomAddress(),
          recipient: randomAddress(),
          destinationToken: randomAddress(),
          amount: randomBigNumber(),
          originChainId: randomBigNumber(2).toString(),
          destinationChainId: OTHER_DESTINATION_CHAIN_ID,
          realizedLpFeePct: randomBigNumber(8, true),
          relayerFeePct: randomBigNumber(8, true),
          depositId: randomBigNumber(2).toString(),
          message: randomBigNumber(100).toHexString(),
        },
        payoutAdjustmentPct: toBN(0),
      });
    }

    // ERC20
    slowFills.push({
      relayData: {
        depositor: depositor.address,
        recipient: recipient.address,
        destinationToken: destErc20.address,
        amount: consts.amountToRelay,
        originChainId: consts.originChainId.toString(),
        destinationChainId: consts.destinationChainId.toString(),
        realizedLpFeePct: consts.realizedLpFeePct,
        relayerFeePct: consts.depositRelayerFeePct,
        depositId: consts.firstDepositId.toString(),
        message: erc20Message,
      },
      payoutAdjustmentPct: ethers.utils.parseEther("9"), // 10x payout.
    });

    // WETH
    slowFills.push({
      relayData: {
        depositor: depositor.address,
        recipient: recipient.address,
        destinationToken: weth.address,
        amount: consts.amountToRelay,
        originChainId: consts.originChainId.toString(),
        destinationChainId: consts.destinationChainId.toString(),
        realizedLpFeePct: consts.realizedLpFeePct,
        relayerFeePct: consts.depositRelayerFeePct,
        depositId: consts.firstDepositId.toString(),
        message: wethMessage,
      },
      payoutAdjustmentPct: ethers.utils.parseEther("-0.5"), // 50% payout.
    });

    // Broken payout adjustment, too small.
    slowFills.push({
      relayData: {
        depositor: depositor.address,
        recipient: recipient.address,
        destinationToken: weth.address,
        amount: consts.amountToRelay,
        originChainId: consts.originChainId.toString(),
        destinationChainId: consts.destinationChainId.toString(),
        realizedLpFeePct: consts.realizedLpFeePct,
        relayerFeePct: consts.depositRelayerFeePct,
        depositId: consts.firstDepositId.toString(),
        message: wethMessage,
      },
      payoutAdjustmentPct: ethers.utils.parseEther("-1.01"), // Over -100% payout.
    });

    // Broken payout adjustment, too large.
    slowFills.push({
      relayData: {
        depositor: depositor.address,
        recipient: recipient.address,
        destinationToken: destErc20.address,
        amount: consts.amountToRelay,
        originChainId: consts.originChainId.toString(),
        destinationChainId: consts.destinationChainId.toString(),
        realizedLpFeePct: consts.realizedLpFeePct,
        relayerFeePct: consts.depositRelayerFeePct,
        depositId: consts.firstDepositId.toString(),
        message: erc20Message,
      },
      payoutAdjustmentPct: ethers.utils.parseEther("101"), // 10000% payout is the limit.
    });

    tree = await buildSlowRelayTree(slowFills);

    await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
  });
  it("Simple SlowRelay ERC20 balances", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            erc20Message,
            ethers.utils.parseEther("9"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === destErc20.address)!)
          )
        )
    ).to.changeTokenBalances(
      destErc20,
      [spokePool, recipient],
      [fullRelayAmountPostFees.mul(10).mul(-1), fullRelayAmountPostFees.mul(10)]
    );
  });
  it("Recipient should be able to execute their own slow relay", async function () {
    await expect(() =>
      spokePool
        .connect(recipient)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            erc20Message,
            ethers.utils.parseEther("9"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === destErc20.address)!)
          )
        )
    ).to.changeTokenBalances(
      destErc20,
      [spokePool, recipient],
      [fullRelayAmountPostFees.mul(10).mul(-1), fullRelayAmountPostFees.mul(10)]
    );
  });

  it("Simple SlowRelay ERC20 FilledRelay event", async function () {
    slowFills.find((slowFill) => slowFill.relayData.destinationToken === destErc20.address)!;

    await expect(
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            erc20Message,
            ethers.utils.parseEther("9"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === destErc20.address)!)
          )
        )
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        consts.amountToRelay,
        consts.amountToRelay,
        consts.amountToRelay,
        0, // Repayment chain ID should always be 0 for slow relay fills.
        consts.originChainId,
        consts.destinationChainId,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.firstDepositId,
        destErc20.address,
        relayer.address,
        depositor.address,
        recipient.address,
        erc20Message,
        [
          recipient.address,
          erc20Message,
          0, // Should not have an applied relayerFeePct for slow relay fills.
          true,
          "9000000000000000000",
        ]
      );
  });

  it("Simple SlowRelay WETH balance", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            wethMessage,
            ethers.utils.parseEther("-0.5"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === weth.address)!)
          )
        )
    ).to.changeTokenBalances(weth, [spokePool], [fullRelayAmountPostFees.div(2).mul(-1)]);
  });

  it("Simple SlowRelay ETH balance", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            wethMessage,
            ethers.utils.parseEther("-0.5"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === weth.address)!)
          )
        )
    ).to.changeEtherBalance(recipient, fullRelayAmountPostFees.div(2));
  });

  it("Partial SlowRelay ERC20 balances", async function () {
    // Work out a partial amount to fill. Send 1/4 of full amount.
    const partialAmount = consts.amountToRelay.mul(toWei("0.25")).div(consts.oneHundredPct);
    // This is the amount that we will actually send to the recipient post-fees.
    const partialAmountPostFees = partialAmount
      .mul(consts.oneHundredPct.sub(consts.depositRelayerFeePct).sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);
    // This is the on-chain remaining amount of the relay.
    const remainingFillAmount = consts.amountToRelay.sub(partialAmount);
    // This is the amount sent to recipient after the slow fill removes the realized LP fee. The relayer fee is credited back to user.
    const slowFillAmountPostFees = remainingFillAmount
      .mul(consts.oneHundredPct.sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);
    await spokePool.connect(relayer).fillRelay(
      ...getFillRelayParams(
        getRelayHash(
          depositor.address,
          recipient.address,
          consts.firstDepositId,
          consts.originChainId,
          consts.destinationChainId,
          destErc20.address,
          consts.amountToRelay,
          undefined,
          undefined,
          erc20Message
        ).relayData,
        partialAmountPostFees, // Set post fee amount as max amount to send so that relay filled amount is
        // decremented by exactly the `partialAmount`.
        consts.destinationChainId // Partial fills must set repayment chain to destination.
      )
    );
    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            erc20Message,
            ethers.utils.parseEther("9"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === destErc20.address)!)
          )
        )
    ).to.changeTokenBalances(
      destErc20,
      [spokePool, recipient],
      [slowFillAmountPostFees.mul(10).mul(-1), slowFillAmountPostFees.mul(10)]
    );
  });

  it("Partial SlowRelay WETH balance", async function () {
    const partialAmount = consts.amountToRelay.mul(toWei("0.25")).div(consts.oneHundredPct);
    const partialAmountPostFees = partialAmount
      .mul(consts.oneHundredPct.sub(consts.depositRelayerFeePct).sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);
    const remainingFillAmount = consts.amountToRelay.sub(partialAmount);
    const slowFillAmountPostFees = remainingFillAmount
      .mul(consts.oneHundredPct.sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);

    await spokePool
      .connect(relayer)
      .fillRelay(
        ...getFillRelayParams(
          getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            consts.destinationChainId,
            weth.address,
            consts.amountToRelay,
            undefined,
            undefined,
            wethMessage
          ).relayData,
          partialAmountPostFees,
          consts.destinationChainId
        )
      );

    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            wethMessage,
            ethers.utils.parseEther("-0.5"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === weth.address)!)
          )
        )
    ).to.changeTokenBalances(weth, [spokePool], [slowFillAmountPostFees.div(2).mul(-1)]);
  });

  it("Partial SlowRelay ETH balance", async function () {
    const partialAmount = consts.amountToRelay.mul(toWei("0.25")).div(consts.oneHundredPct);
    const partialAmountPostFees = partialAmount
      .mul(consts.oneHundredPct.sub(consts.depositRelayerFeePct).sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);
    const remainingFillAmount = consts.amountToRelay.sub(partialAmount);
    const slowFillAmountPostFees = remainingFillAmount
      .mul(consts.oneHundredPct.sub(consts.realizedLpFeePct))
      .div(consts.oneHundredPct);

    await spokePool
      .connect(relayer)
      .fillRelay(
        ...getFillRelayParams(
          getRelayHash(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            consts.destinationChainId,
            weth.address,
            consts.amountToRelay,
            undefined,
            undefined,
            wethMessage
          ).relayData,
          partialAmountPostFees,
          consts.destinationChainId
        )
      );

    await expect(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            wethMessage,
            ethers.utils.parseEther("-0.5"),
            tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === weth.address)!)
          )
        )
    ).to.changeEtherBalance(recipient, slowFillAmountPostFees.div(2));
  });

  it("Payout adjustment too large", async function () {
    await expect(
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            erc20Message,
            ethers.utils.parseEther("101"),
            tree.getHexProof(
              slowFills.find(
                (slowFill) =>
                  slowFill.relayData.destinationToken === destErc20.address &&
                  slowFill.payoutAdjustmentPct.eq(ethers.utils.parseEther("101"))
              )!
            )
          )
        )
    ).to.revertedWith("payoutAdjustmentPct too large");
  });

  it("Payout adjustment too small", async function () {
    await expect(
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            wethMessage,
            ethers.utils.parseEther("-1.01"),
            tree.getHexProof(
              slowFills.find(
                (slowFill) =>
                  slowFill.relayData.destinationToken === weth.address &&
                  slowFill.payoutAdjustmentPct.eq(ethers.utils.parseEther("-1.01"))
              )!
            )
          )
        )
    ).to.revertedWith("payoutAdjustmentPct too small");
  });

  it("Bad proof: Relay data is correct except that destination chain ID doesn't match spoke pool's", async function () {
    const slowFill = slowFills.find((fill) => fill.relayData.destinationChainId === OTHER_DESTINATION_CHAIN_ID)!;

    // This should revert because the relay struct that we found via .find() is the one inserted in the merkle root
    // published to the spoke pool, but its destination chain ID is OTHER_DESTINATION_CHAIN_ID, which is different
    // than the spoke pool's destination chain ID.
    await expect(
      spokePool
        .connect(relayer)
        .executeSlowRelayLeaf(
          ...getExecuteSlowRelayParams(
            slowFill.relayData.depositor,
            slowFill.relayData.recipient,
            slowFill.relayData.destinationToken,
            toBN(slowFill.relayData.amount),
            Number(slowFill.relayData.originChainId),
            toBN(slowFill.relayData.realizedLpFeePct),
            toBN(slowFill.relayData.relayerFeePct),
            Number(slowFill.relayData.depositId),
            0,
            slowFill.relayData.message,
            ZERO,
            tree.getHexProof(slowFill!)
          )
        )
    ).to.be.revertedWith("Invalid slow relay proof");
  });

  it("Bad proof: Relay data besides destination chain ID is not included in merkle root", async function () {
    await expect(
      spokePool.connect(relayer).executeSlowRelayLeaf(
        ...getExecuteSlowRelayParams(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay.sub(1), // Slightly modify the relay data from the expected set.
          consts.originChainId,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          0,
          "0x1234",
          ZERO,
          tree.getHexProof(slowFills.find((slowFill) => slowFill.relayData.destinationToken === weth.address)!)
        )
      )
    ).to.be.reverted;
  });

  describe("requestUSSSlowFill", function () {
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
        outputAmount: fullRelayAmountPostFees,
        originChainId: consts.originChainId,
        depositId: consts.firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
    });
    it("can send before fast fill", async function () {
      const relayHash = getUSSRelayHash(relayData, consts.destinationChainId);

      expect(await spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.emit(spokePool, "RequestedUSSSlowFill");
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.RequestedSlowFill);

      // Can't slow fill again
      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );

      // Can fast fill after.
      await spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId);
    });
    it("can't send after fast fill", async function () {
      await spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId);
      const relayHash = getUSSRelayHash(relayData, consts.destinationChainId);
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.Filled);

      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );
    });
  });
  describe("executeUSSSlowRelayLeaf", function () {
    let relayData: USSRelayData, slowRelayLeaf: USSSlowFill;
    beforeEach(async function () {
      const fillDeadline = (await spokePool.getCurrentTime()).toNumber() + 1000;
      relayData = {
        depositor: depositor.address,
        recipient: recipient.address,
        exclusiveRelayer: relayer.address,
        inputToken: erc20.address,
        outputToken: destErc20.address,
        inputAmount: consts.amountToDeposit,
        outputAmount: fullRelayAmountPostFees,
        originChainId: consts.originChainId,
        depositId: consts.firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
      slowRelayLeaf = {
        relayData,
        chainId: consts.destinationChainId,
        updatedOutputAmount: relayData.outputAmount,
      };
    });
    it("can send ERC20 with correct proof", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(() =>
        spokePool
          .connect(relayer)
          .executeUSSSlowRelayLeaf(
            slowRelayLeaf,
            1, // rootBundleId
            tree.getHexProof(slowRelayLeaf)
          )
          .to.changeTokenBalances(
            destErc20,
            [spokePool, recipient],
            [slowRelayLeaf.updatedOutputAmount.mul(-1), slowRelayLeaf.updatedOutputAmount]
          )
      );
    });
  });
});
