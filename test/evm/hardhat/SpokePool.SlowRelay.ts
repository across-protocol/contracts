import {
  expect,
  Contract,
  ethers,
  SignerWithAddress,
  toBN,
  seedContract,
  seedWallet,
  addressToBytes,
  hashNonEmptyMessage,
} from "../../../utils/utils";
import { spokePoolFixture, V3RelayData, getV3RelayHash, V3SlowFill, FillType } from "./fixtures/SpokePool.Fixture";
import { buildV3SlowRelayTree } from "./MerkleLib.utils";
import * as consts from "./constants";
import { FillStatus } from "../../../utils/constants";
import { SpokePoolFuncs } from "./constants";

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

  describe("requestV3SlowFill", function () {
    let relayData: V3RelayData;
    beforeEach(async function () {
      const fillDeadline = (await spokePool.getCurrentTime()).toNumber() + 1000;
      relayData = {
        depositor: addressToBytes(depositor.address),
        recipient: addressToBytes(recipient.address),
        exclusiveRelayer: addressToBytes(relayer.address),
        inputToken: addressToBytes(erc20.address),
        outputToken: addressToBytes(destErc20.address),
        inputAmount: consts.amountToDeposit,
        outputAmount: fullRelayAmountPostFees,
        originChainId: consts.originChainId,
        depositId: consts.firstDepositId,
        fillDeadline: fillDeadline,
        exclusivityDeadline: fillDeadline - 500,
        message: "0x",
      };
      // By default, set current time to after exclusivity deadline
      await spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);
    });
    it("fill deadline is expired", async function () {
      relayData.fillDeadline = (await spokePool.getCurrentTime()).sub(1);
      await expect(spokePool.connect(relayer).requestV3SlowFill(relayData)).to.be.revertedWith("ExpiredFillDeadline");
    });
    it("in absence of exclusivity", async function () {
      // Clock drift between spokes can mean exclusivityDeadline is in future even when no exclusivity was applied.
      await spokePool.setCurrentTime(relayData.exclusivityDeadline - 1);
      await expect(spokePool.connect(relayer).requestV3SlowFill({ ...relayData, exclusivityDeadline: 0 })).to.emit(
        spokePool,
        "RequestedV3SlowFill"
      );
    });
    it("during exclusivity deadline", async function () {
      await spokePool.setCurrentTime(relayData.exclusivityDeadline);
      await expect(spokePool.connect(relayer).requestV3SlowFill(relayData)).to.be.revertedWith(
        "NoSlowFillsInExclusivityWindow"
      );
    });
    it("can request before fast fill", async function () {
      const relayHash = getV3RelayHash(relayData, consts.destinationChainId);

      // FillStatus must be Unfilled:
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.Unfilled);
      expect(await spokePool.connect(relayer).requestV3SlowFill(relayData)).to.emit(spokePool, "RequestedV3SlowFill");

      // FillStatus gets reset to RequestedSlowFill:
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.RequestedSlowFill);

      // Can't request slow fill again:
      await expect(spokePool.connect(relayer).requestV3SlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );

      // Can fast fill after:
      await spokePool
        .connect(relayer)
        [SpokePoolFuncs.fillV3RelayBytes](relayData, consts.repaymentChainId, addressToBytes(relayer.address));
    });
    it("cannot request if FillStatus is Filled", async function () {
      const relayHash = getV3RelayHash(relayData, consts.destinationChainId);
      await spokePool.setFillStatus(relayHash, FillStatus.Filled);
      expect(await spokePool.fillStatuses(relayHash)).to.equal(FillStatus.Filled);
      await expect(spokePool.connect(relayer).requestV3SlowFill(relayData)).to.be.revertedWith(
        "InvalidSlowFillRequest"
      );
    });
    it("fills are not paused", async function () {
      await spokePool.pauseFills(true);
      await expect(spokePool.connect(relayer).requestV3SlowFill(relayData)).to.be.revertedWith("FillsArePaused");
    });
    it("reentrancy protected", async function () {
      // In this test we create a reentrancy attempt by sending a fill with a recipient contract that calls back into
      // the spoke pool via the tested function.
      const functionCalldata = spokePool.interface.encodeFunctionData("requestV3SlowFill", [relayData]);
      await expect(spokePool.connect(depositor).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
  });
  describe("executeV3SlowRelayLeaf", function () {
    let relayData: V3RelayData, slowRelayLeaf: V3SlowFill;
    beforeEach(async function () {
      const fillDeadline = (await spokePool.getCurrentTime()).toNumber() + 1000;
      relayData = {
        depositor: addressToBytes(depositor.address),
        recipient: addressToBytes(recipient.address),
        exclusiveRelayer: addressToBytes(relayer.address),
        inputToken: addressToBytes(erc20.address),
        outputToken: addressToBytes(destErc20.address),
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
        // outputAmount when calling _verifyV3SlowFill.
        updatedOutputAmount: relayData.outputAmount.add(1),
      };
    });
    it("Happy case: recipient can send ERC20 with correct proof out of contract balance", async function () {
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(() =>
        spokePool.connect(recipient).executeV3SlowRelayLeaf(
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
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await spokePool.connect(relayer).executeV3SlowRelayLeaf(
        slowRelayLeaf,
        0, // rootBundleId
        tree.getHexProof(slowRelayLeaf)
      );
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.be.revertedWith("RelayFilled");

      // Cannot fast fill after slow fill
      await expect(
        spokePool
          .connect(relayer)
          [SpokePoolFuncs.fillV3RelayBytes](
            slowRelayLeaf.relayData,
            consts.repaymentChainId,
            addressToBytes(relayer.address)
          )
      ).to.be.revertedWith("RelayFilled");
    });
    it("cannot be used to double send a fill", async function () {
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());

      // Fill before executing slow fill
      await spokePool
        .connect(relayer)
        [SpokePoolFuncs.fillV3RelayBytes](
          slowRelayLeaf.relayData,
          consts.repaymentChainId,
          addressToBytes(relayer.address)
        );
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.be.revertedWith("RelayFilled");
    });
    it("cannot re-enter", async function () {
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      const functionCalldata = spokePool.interface.encodeFunctionData("executeV3SlowRelayLeaf", [
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
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.not.be.reverted;
    });
    it("executes _preExecuteLeafHook", async function () {
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      )
        .to.emit(spokePool, "PreLeafExecuteHook")
        .withArgs(slowRelayLeaf.relayData.outputToken.toLowerCase());
    });
    it("cannot execute leaves with chain IDs not matching spoke pool's chain ID", async function () {
      // In this test, the merkle proof is valid for the tree relayed to the spoke pool, but the merkle leaf
      // destination chain ID does not match the spoke pool's chainId() and therefore cannot be executed.
      const slowRelayLeafWithWrongDestinationChain: V3SlowFill = {
        ...slowRelayLeaf,
        chainId: slowRelayLeaf.chainId + 1,
      };
      const treeWithWrongDestinationChain = await buildV3SlowRelayTree([slowRelayLeafWithWrongDestinationChain]);
      await spokePool
        .connect(depositor)
        .relayRootBundle(consts.mockTreeRoot, treeWithWrongDestinationChain.getHexRoot());
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeafWithWrongDestinationChain,
          0, // rootBundleId
          treeWithWrongDestinationChain.getHexProof(slowRelayLeafWithWrongDestinationChain)
        )
      ).to.be.revertedWith("InvalidMerkleProof");
    });
    it("_verifyV3SlowFill", async function () {
      const leafWithDifferentUpdatedOutputAmount = {
        ...slowRelayLeaf,
        updatedOutputAmount: slowRelayLeaf.updatedOutputAmount.add(1),
      };

      const tree = await buildV3SlowRelayTree([slowRelayLeaf, leafWithDifferentUpdatedOutputAmount]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, consts.mockTreeRoot);

      // Incorrect root bundle ID
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          1, // rootBundleId should be 0
          tree.getHexProof(slowRelayLeaf)
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Invalid proof
      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0,
          tree.getHexProof(leafWithDifferentUpdatedOutputAmount) // Invalid proof
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect relay execution params, not matching leaf used to construct proof
      await expect(
        spokePool
          .connect(relayer)
          .executeV3SlowRelayLeaf(leafWithDifferentUpdatedOutputAmount, 0, tree.getHexProof(slowRelayLeaf))
      ).to.revertedWith("InvalidMerkleProof");
    });
    it("calls _fillRelay with expected params", async function () {
      const tree = await buildV3SlowRelayTree([slowRelayLeaf]);
      await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());

      await expect(
        spokePool.connect(relayer).executeV3SlowRelayLeaf(
          slowRelayLeaf,
          0, // rootBundleId
          tree.getHexProof(slowRelayLeaf)
        )
      )
        .to.emit(spokePool, "FilledV3Relay")
        .withArgs(
          addressToBytes(relayData.inputToken),
          addressToBytes(relayData.outputToken),
          relayData.inputAmount,
          relayData.outputAmount,
          0, // Sets repaymentChainId to 0.
          relayData.originChainId,
          relayData.depositId,
          relayData.fillDeadline,
          relayData.exclusivityDeadline,
          addressToBytes(relayData.exclusiveRelayer),
          addressToBytes(consts.zeroAddress), // Sets relayer address to 0x0
          addressToBytes(relayData.depositor),
          addressToBytes(relayData.recipient),
          hashNonEmptyMessage(relayData.message),
          [
            // Uses relayData.recipient
            addressToBytes(relayData.recipient),
            // Uses relayData.message
            hashNonEmptyMessage(relayData.message),
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
