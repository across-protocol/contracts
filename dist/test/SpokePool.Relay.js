"use strict";
var __createBinding =
  (this && this.__createBinding) ||
  (Object.create
    ? function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        Object.defineProperty(o, k2, {
          enumerable: true,
          get: function () {
            return m[k];
          },
        });
      }
    : function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        o[k2] = m[k];
      });
var __setModuleDefault =
  (this && this.__setModuleDefault) ||
  (Object.create
    ? function (o, v) {
        Object.defineProperty(o, "default", { enumerable: true, value: v });
      }
    : function (o, v) {
        o["default"] = v;
      });
var __importStar =
  (this && this.__importStar) ||
  function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null)
      for (var k in mod)
        if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
  };
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const SpokePool_Fixture_2 = require("./fixtures/SpokePool.Fixture");
const consts = __importStar(require("./constants"));
let spokePool, weth, erc20, destErc20;
let depositor, recipient, relayer;
describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await utils_1.ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await (0, utils_1.seedWallet)(depositor, [erc20], weth, consts.amountToSeedWallets);
    await (0, utils_1.seedWallet)(relayer, [destErc20], weth, consts.amountToSeedWallets);
    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, consts.amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, consts.amountToDeposit);
    await weth.connect(relayer).approve(spokePool.address, consts.amountToDeposit);
    // Whitelist origin token => destination chain ID routes:
    await (0,
    SpokePool_Fixture_1.enableRoutes)(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);
  });
  it("Relaying ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const { relayHash, relayData } = (0, SpokePool_Fixture_1.getRelayHash)(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelay(...(0, SpokePool_Fixture_2.getFillRelayParams)(relayData, consts.amountToRelay))
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.amount,
        consts.amountToRelayPreFees,
        consts.amountToRelayPreFees,
        consts.repaymentChainId,
        (0, utils_1.toBN)(relayData.originChainId),
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        (0, utils_1.toBN)(relayData.depositId),
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );
    // The collateral should have transferred from relayer to recipient.
    (0, utils_1.expect)(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(consts.amountToRelay)
    );
    (0, utils_1.expect)(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);
    // Fill amount should be set.
    (0, utils_1.expect)(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);
    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = consts.amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount
      .mul(consts.totalPostFeesPct)
      .div((0, utils_1.toBN)(consts.oneHundredPct));
    await spokePool
      .connect(relayer)
      .fillRelay(...(0, SpokePool_Fixture_2.getFillRelayParams)(relayData, fullRelayAmount));
    (0, utils_1.expect)(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(fullRelayAmountPostFees)
    );
    (0, utils_1.expect)(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);
    // Fill amount should be equal to full relay amount.
    (0, utils_1.expect)(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = (0, SpokePool_Fixture_1.getRelayHash)(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      weth.address
    );
    const startingRecipientBalance = await recipient.getBalance();
    await spokePool
      .connect(relayer)
      .fillRelay(...(0, SpokePool_Fixture_2.getFillRelayParams)(relayData, consts.amountToRelay));
    // The collateral should have unwrapped to ETH and then transferred to recipient.
    (0, utils_1.expect)(await weth.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(consts.amountToRelay)
    );
    (0, utils_1.expect)(await recipient.getBalance()).to.equal(startingRecipientBalance.add(consts.amountToRelay));
    // Fill amount should be set.
    (0, utils_1.expect)(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);
  });
  it("General failure cases", async function () {
    // Fees set too high.
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...(0, SpokePool_Fixture_2.getFillRelayParams)(
            (0, SpokePool_Fixture_1.getRelayHash)(
              depositor.address,
              recipient.address,
              consts.firstDepositId,
              consts.originChainId,
              destErc20.address,
              consts.amountToDeposit.toString(),
              (0, utils_1.toWei)("0.5").toString(),
              consts.depositRelayerFeePct.toString()
            ).relayData,
            consts.amountToRelay,
            consts.repaymentChainId
          )
        )
    ).to.be.revertedWith("invalid fees");
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelay(
          ...(0, SpokePool_Fixture_2.getFillRelayParams)(
            (0, SpokePool_Fixture_1.getRelayHash)(
              depositor.address,
              recipient.address,
              consts.firstDepositId,
              consts.originChainId,
              destErc20.address,
              consts.amountToDeposit.toString(),
              consts.realizedLpFeePct.toString(),
              (0, utils_1.toWei)("0.5").toString()
            ).relayData,
            consts.amountToRelay,
            consts.repaymentChainId
          )
        )
    ).to.be.revertedWith("invalid fees");
    // Relay already filled
    await spokePool.connect(relayer).fillRelay(
      ...(0, SpokePool_Fixture_2.getFillRelayParams)(
        (0, SpokePool_Fixture_1.getRelayHash)(
          depositor.address,
          recipient.address,
          consts.firstDepositId,
          consts.originChainId,
          destErc20.address
        ).relayData,
        consts.amountToDeposit, // Send the full relay amount
        consts.repaymentChainId
      )
    );
    await (0, utils_1.expect)(
      spokePool.connect(relayer).fillRelay(
        ...(0, SpokePool_Fixture_2.getFillRelayParams)(
          (0, SpokePool_Fixture_1.getRelayHash)(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address
          ).relayData,
          (0, utils_1.toBN)("1"), // relay any amount
          consts.repaymentChainId
        )
      )
    ).to.be.revertedWith("relay filled");
  });
  it("Can signal to relayer to use updated fee", async function () {
    const spokePoolChainId = await spokePool.chainId();
    const { signature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      consts.firstDepositId.toString(),
      spokePoolChainId.toString(),
      depositor
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .speedUpDeposit(depositor.address, consts.modifiedRelayerFeePct, consts.firstDepositId, signature)
    )
      .to.emit(spokePool, "RequestedSpeedUpDeposit")
      .withArgs(consts.modifiedRelayerFeePct, consts.firstDepositId, depositor.address, signature);
    // Reverts if any param passed to function is changed.
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .speedUpDeposit(relayer.address, consts.modifiedRelayerFeePct, consts.firstDepositId, signature)
    ).to.be.reverted;
    await (0, utils_1.expect)(
      spokePool.connect(relayer).speedUpDeposit(depositor.address, "0", consts.firstDepositId, signature)
    ).to.be.reverted;
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .speedUpDeposit(depositor.address, consts.modifiedRelayerFeePct, consts.firstDepositId + 1, signature)
    ).to.be.reverted;
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .speedUpDeposit(depositor.address, consts.modifiedRelayerFeePct, consts.firstDepositId, "0xrandombytes")
    ).to.be.reverted;
    const { signature: incorrectOriginChainIdSignature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      consts.firstDepositId.toString(),
      consts.originChainId.toString(),
      depositor
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .speedUpDeposit(
          depositor.address,
          consts.modifiedRelayerFeePct,
          consts.firstDepositId,
          incorrectOriginChainIdSignature
        )
    ).to.be.reverted;
  });
  it("Can fill relay with updated fee by including proof of depositor's agreement", async function () {
    // The relay should succeed just like before with the same amount of tokens pulled from the relayer's wallet,
    // however the filled amount should have increased since the proportion of the relay filled would increase with a
    // higher fee.
    const { relayHash, relayData } = (0, SpokePool_Fixture_1.getRelayHash)(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );
    const { signature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    await spokePool
      .connect(relayer)
      .fillRelayWithUpdatedFee(
        ...(0, SpokePool_Fixture_2.getFillRelayUpdatedFeeParams)(
          relayData,
          consts.amountToRelay,
          consts.modifiedRelayerFeePct,
          signature
        )
      );
    // The collateral should have transferred from relayer to recipient.
    (0, utils_1.expect)(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(consts.amountToRelay)
    );
    (0, utils_1.expect)(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);
    // Fill amount should be be set taking into account modified fees.
    (0, utils_1.expect)(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreModifiedFees);
  });
  it("Updating relayer fee signature verification failure cases", async function () {
    const { relayData } = (0, SpokePool_Fixture_1.getRelayHash)(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );
    // Message hash doesn't contain the modified fee passed as a function param.
    const { signature: incorrectFeeSignature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.incorrectModifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...(0, SpokePool_Fixture_2.getFillRelayUpdatedFeeParams)(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectFeeSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
    // Relay data depositID and originChainID don't match data included in relay hash
    const { signature: incorrectDepositIdSignature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      relayData.depositId + "1",
      relayData.originChainId,
      depositor
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...(0, SpokePool_Fixture_2.getFillRelayUpdatedFeeParams)(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectDepositIdSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
    const { signature: incorrectChainIdSignature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId + "1",
      depositor
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...(0, SpokePool_Fixture_2.getFillRelayUpdatedFeeParams)(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectChainIdSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
    // Message hash must be signed by depositor passed in function params.
    const { signature: incorrectSignerSignature } = await (0, SpokePool_Fixture_1.modifyRelayHelper)(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      relayer
    );
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...(0, SpokePool_Fixture_2.getFillRelayUpdatedFeeParams)(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectSignerSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
  });
});
