import { expect, Contract, ethers, SignerWithAddress, seedWallet, toWei, toBN } from "./utils";
import {
  spokePoolFixture,
  enableRoutes,
  getRelayHash,
  modifyRelayHelper,
  getFillRelayParams,
  getFillRelayUpdatedFeeParams,
} from "./SpokePool.Fixture";
import * as consts from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

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

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);
  });
  it("Relaying ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );

    await expect(spokePool.connect(relayer).fillRelay(...getFillRelayParams(relayData, consts.amountToRelay)))
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        relayData.relayAmount,
        consts.amountToRelayPreFees,
        consts.amountToRelayPreFees,
        relayData.relayerFeePct,
        relayData.realizedLpFeePct,
        consts.repaymentChainId,
        toBN(relayData.originChainId),
        toBN(relayData.depositId),
        relayData.destinationToken,
        relayer.address,
        relayData.depositor,
        relayData.recipient
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);

    // Relay again with maxAmountOfTokensToSend > amount of the relay remaining and check that the contract
    // pulls exactly enough tokens to complete the relay.
    const fullRelayAmount = consts.amountToDeposit;
    const fullRelayAmountPostFees = fullRelayAmount.mul(consts.totalPostFeesPct).div(toBN(consts.oneHundredPct));
    await spokePool.connect(relayer).fillRelay(...getFillRelayParams(relayData, fullRelayAmount));
    expect(await destErc20.balanceOf(relayer.address)).to.equal(
      consts.amountToSeedWallets.sub(fullRelayAmountPostFees)
    );
    expect(await destErc20.balanceOf(recipient.address)).to.equal(fullRelayAmountPostFees);

    // Fill amount should be equal to full relay amount.
    expect(await spokePool.relayFills(relayHash)).to.equal(fullRelayAmount);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      weth.address
    );

    const startingRecipientBalance = await recipient.getBalance();
    await spokePool.connect(relayer).fillRelay(...getFillRelayParams(relayData, consts.amountToRelay));

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(consts.amountToRelay));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreFees);
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
              destErc20.address,
              consts.amountToDeposit.toString(),
              toWei("0.5").toString(),
              consts.depositRelayerFeePct.toString()
            ).relayData,
            consts.amountToRelay,
            consts.repaymentChainId
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
              destErc20.address,
              consts.amountToDeposit.toString(),
              consts.realizedLpFeePct.toString(),
              toWei("0.5").toString()
            ).relayData,
            consts.amountToRelay,
            consts.repaymentChainId
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
          destErc20.address
        ).relayData,
        consts.amountToDeposit, // Send the full relay amount
        consts.repaymentChainId
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
            destErc20.address
          ).relayData,
          toBN("1"), // relay any amount
          consts.repaymentChainId
        )
      )
    ).to.be.revertedWith("relay filled");
  });
  it("Can fill relay with updated fee by including proof of depositor's agreement", async function () {
    // The relay should succeed just like before with the same amount of tokens pulled from the relayer's wallet,
    // however the filled amount should have increased since the proportion of the relay filled would increase with a
    // higher fee.
    const { relayHash, relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );
    const { signature } = await modifyRelayHelper(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    await spokePool
      .connect(relayer)
      .fillRelayWithUpdatedFee(
        ...getFillRelayUpdatedFeeParams(relayData, consts.amountToRelay, consts.modifiedRelayerFeePct, signature)
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToSeedWallets.sub(consts.amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(consts.amountToRelay);

    // Fill amount should be be set taking into account modified fees.
    expect(await spokePool.relayFills(relayHash)).to.equal(consts.amountToRelayPreModifiedFees);
  });
  it("Updating relayer fee signature verification failure cases", async function () {
    const { relayData } = getRelayHash(
      depositor.address,
      recipient.address,
      consts.firstDepositId,
      consts.originChainId,
      destErc20.address
    );

    // Message hash doesn't contain the modified fee passed as a function param.
    const { signature: incorrectFeeSignature } = await modifyRelayHelper(
      consts.incorrectModifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...getFillRelayUpdatedFeeParams(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectFeeSignature
          )
        )
    ).to.be.revertedWith("invalid signature");

    // Relay data depositID and originChainID don't match data included in relay hash
    const { signature: incorrectDepositIdSignature } = await modifyRelayHelper(
      consts.modifiedRelayerFeePct,
      relayData.depositId + "1",
      relayData.originChainId,
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...getFillRelayUpdatedFeeParams(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectDepositIdSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
    const { signature: incorrectChainIdSignature } = await modifyRelayHelper(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId + "1",
      depositor
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...getFillRelayUpdatedFeeParams(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectChainIdSignature
          )
        )
    ).to.be.revertedWith("invalid signature");

    // Message hash must be signed by depositor passed in function params.
    const { signature: incorrectSignerSignature } = await modifyRelayHelper(
      consts.modifiedRelayerFeePct,
      relayData.depositId,
      relayData.originChainId,
      relayer
    );
    await expect(
      spokePool
        .connect(relayer)
        .fillRelayWithUpdatedFee(
          ...getFillRelayUpdatedFeeParams(
            relayData,
            consts.amountToRelay,
            consts.modifiedRelayerFeePct,
            incorrectSignerSignature
          )
        )
    ).to.be.revertedWith("invalid signature");
  });
});
