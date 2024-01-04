import { expect, Contract, ethers, SignerWithAddress, toBN, seedContract, seedWallet } from "../utils/utils";
import { spokePoolFixture, USSRelayData, getUSSRelayHash, USSSlowFill, FillType } from "./fixtures/SpokePool.Fixture";
import { buildUSSSlowRelayTree } from "./MerkleLib.utils";
import * as consts from "./constants";
import { FillStatus } from "../utils/constants";

let spokePool: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

// Relay fees for slow relay are only the realizedLpFee; the depositor should be re-funded the relayer fee
// for any amount sent by a slow relay.
const fullRelayAmountPostFees = consts.amountToRelay
  .mul(toBN(consts.oneHundredPct).sub(consts.realizedLpFeePct))
  .div(toBN(consts.oneHundredPct));

describe("SpokePool Slow Relay Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ spokePool, destErc20, erc20 } = await spokePoolFixture());

    // Send tokens to the spoke pool for repayment and relayer to send fills
    await seedContract(spokePool, relayer, [destErc20], undefined, fullRelayAmountPostFees.mul(10));

    // Approve spoke pool to take relayer's tokens.
    await seedWallet(relayer, [destErc20], undefined, consts.amountToSeedWallets);
    await destErc20.connect(relayer).approve(spokePool.address, consts.maxUint256);
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
    it("fill deadline is expired", async function () {
      relayData.fillDeadline = (await spokePool.getCurrentTime()).sub(1);
      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith("ExpiredFillDeadline");
    });
    it("can request before fast fill", async function () {
      const relayHash = getUSSRelayHash(relayData, consts.destinationChainId);

      // FillStatus must be Unfilled:
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.Unfilled);
      expect(await spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.emit(spokePool, "RequestedUSSSlowFill");

      // FillStatus gets reset to RequestedSlowFill:
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.RequestedSlowFill);

      // Can't request slow fill again:
      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );

      // Can fast fill after:
      await spokePool.connect(relayer).fillUSSRelay(relayData, consts.repaymentChainId);
    });
    it("cannot request if FillStatus is Filled", async function () {
      const relayHash = getUSSRelayHash(relayData, consts.destinationChainId);
      await spokePool.setFillStatus(relayHash, FillStatus.Filled);
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.Filled);
      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );
    });
    it("fills are not paused", async function () {
      await spokePool.pauseFills(true);
      await expect(spokePool.connect(relayer).requestUSSSlowFill(relayData)).to.be.revertedWith("Paused fills");
    });
    it("reentrancy protected", async function () {
      // In this test we create a reentrancy attempt by sending a fill with a recipient contract that calls back into
      // the spoke pool via the tested function.
      const functionCalldata = spokePool.interface.encodeFunctionData("requestUSSSlowFill", [relayData]);
      await expect(spokePool.connect(depositor).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
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
        // Make updated output amount different to test whether it is used instead of
        // outputAmount when calling _verifyUSSSlowFill.
        updatedOutputAmount: relayData.outputAmount.add(1),
      };
    });
    it("Happy case: recipient can send ERC20 with correct proof out of contract balance", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(() =>
        spokePool.connect(recipient).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.changeTokenBalances(
        destErc20,
        [spokePool, recipient],
        [slowRelayLeaf.updatedOutputAmount.mul(-1), slowRelayLeaf.updatedOutputAmount]
      );
    });
    it("cannot double execute leaf", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await spokePool.connect(relayer).executeUSSSlowRelayLeaf(
        slowRelayLeaf,
        0, // rootBundleId
        tree.getHexProof(slowRelayLeaf)
      );
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.be.revertedWith("RelayFilled");

      // Cannot fast fill after slow fill
      await expect(
        spokePool.connect(relayer).fillUSSRelay(slowRelayLeaf.relayData, consts.repaymentChainId)
      ).to.be.revertedWith("RelayFilled");
    });
    it("cannot be used to double send a fill", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());

      // Fill before executing slow fill
      await spokePool.connect(relayer).fillUSSRelay(slowRelayLeaf.relayData, consts.repaymentChainId);
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.be.revertedWith("RelayFilled");
    });
    it("cannot re-enter", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      const functionCalldata = spokePool.interface.encodeFunctionData("executeUSSSlowRelayLeaf", [
        slowRelayLeaf,
        0, // rootBundleId
        tree.getHexProof(slowRelayLeaf),
      ]);
      await expect(spokePool.connect(depositor).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
    it("can execute even if fills are paused", async function () {
      await spokePool.pauseFills(true);
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.not.be.reverted;
    });
    it("executes _preExecuteLeafHook", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      )
        .to.emit(spokePool, "PreLeafExecuteHook")
        .withArgs(slowRelayLeaf.relayData.outputToken);
    });
    it("cannot execute leaves with chain IDs not matching spoke pool's chain ID", async function () {
      // In this test, the merkle proof is valid for the tree relayed to the spoke pool, but the merkle leaf
      // destination chain ID does not match the spoke pool's chainId() and therefore cannot be executed.
      const slowRelayLeafWithWrongDestinationChain: USSSlowFill = {
        ...slowRelayLeaf,
        chainId: slowRelayLeaf.chainId + 1,
      };
      const treeWithWrongDestinationChain = await buildUSSSlowRelayTree([slowRelayLeafWithWrongDestinationChain]);
      await spokePool
        .connect(depositor)
        .relayRootBundle(consts.mockTreeRoot, treeWithWrongDestinationChain.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeafWithWrongDestinationChain,
          0, // rootBundleId
          treeWithWrongDestinationChain.getHexProof(slowRelayLeafWithWrongDestinationChain)
        )
      ).to.be.revertedWith("InvalidMerkleProof");
    });
    it("_verifyUSSSlowFill", async function () {
      const leafWithDifferentUpdatedOutputAmount = {
        ...slowRelayLeaf,
        updatedOutputAmount: slowRelayLeaf.updatedOutputAmount.add(1),
      };

      const tree = await buildUSSSlowRelayTree([slowRelayLeaf, leafWithDifferentUpdatedOutputAmount]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, consts.mockTreeRoot);

      // Incorrect root bundle ID
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          1, // rootBundleId should be 0
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Invalid proof
      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0,
          tree.getHexProof(leafWithDifferentUpdatedOutputAmount) // Invalid proof
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect relay execution params, not matching leaf used to construct proof
      await expect(
        spokePool
          .connect(relayer)
          .executeUSSSlowRelayLeaf(leafWithDifferentUpdatedOutputAmount, 0, tree.getHexProof(slowRelayLeaf))
      ).to.revertedWith("InvalidMerkleProof");
    });
    it("calls _fillRelay with expected params", async function () {
      const tree = await buildUSSSlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());

      await expect(
        spokePool.connect(relayer).executeUSSSlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      )
        .to.emit(spokePool, "FilledUSSRelay")
        .withArgs(
          relayData.inputToken,
          relayData.outputToken,
          relayData.inputAmount,
          relayData.outputAmount,
          // Sets repaymentChainId to 0:
          0,
          relayData.originChainId,
          relayData.depositId,
          relayData.fillDeadline,
          relayData.exclusivityDeadline,
          relayData.exclusiveRelayer,
          // Sets relayer address to 0x0
          consts.zeroAddress,
          relayData.depositor,
          relayData.recipient,
          relayData.message,
          [
            // Uses relayData.recipient
            relayData.recipient,
            // Uses relayData.message
            relayData.message,
            // Uses slow fill leaf's updatedOutputAmount
            slowRelayLeaf.updatedOutputAmount,
            // Should be SlowFill
            FillType.SlowFill,
          ]
        );

      // Sanity check that executed slow fill leaf's updatedOutputAmount is different than the relayData.outputAmount
      // since we test for it above.
      expect(slowRelayLeaf.relayData.outputAmount).to.not.equal(slowRelayLeaf.updatedOutputAmount);
    });
  });
});
