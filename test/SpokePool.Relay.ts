import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, seedWallet, toWei } from "./utils";
import { deploySpokePoolTestHelperContracts, enableRoutes, getRelayHash } from "./SpokePool.Fixture";
import {
  amountToSeedWallets,
  amountToDeposit,
  amountToRelay,
  amountToRelayPreFees,
  originChainId,
  repaymentChainId,
  firstDepositId,
} from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

describe("SpokePool Relayer Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await deploySpokePoolTestHelperContracts(depositor));

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, amountToSeedWallets);

    // Approve spokepool to spend tokens
    await erc20.connect(depositor).approve(spokePool.address, amountToDeposit);
    await weth.connect(depositor).approve(spokePool.address, amountToDeposit);
    await destErc20.connect(relayer).approve(spokePool.address, amountToRelay);
    await weth.connect(relayer).approve(spokePool.address, amountToRelay);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [
      {
        originToken: erc20.address,
      },
      {
        originToken: weth.address,
      },
    ]);
  });
  it("Relaying ERC20 tokens correctly pulls tokens and changes contract state", async function () {
    const { relayHash, relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        firstDepositId,
        originChainId,
        destErc20.address
    )

    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
            relayData[0],
            relayData[1],
            relayData[2],
            relayData[3],
            relayData[4],
            relayData[5],
            relayData[6],
            relayData[7],
            amountToRelay,
            repaymentChainId
        )
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        amountToRelayPreFees,
        repaymentChainId,
        amountToRelay,
        relayer.address,
        relayData
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(amountToRelay);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreFees);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        firstDepositId,
        originChainId,
        weth.address
    )

    const startingRecipientBalance = await recipient.getBalance()
    await expect(
      spokePool
        .connect(relayer)
        .fillRelay(
            relayData[0],
            relayData[1],
            relayData[2],
            relayData[3],
            relayData[4],
            relayData[5],
            relayData[6],
            relayData[7],
            amountToRelay,
            repaymentChainId
        )
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        amountToRelayPreFees,
        repaymentChainId,
        amountToRelay,
        relayer.address,
        relayData
      );

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelay));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(amountToRelay));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelayPreFees);
  });
  it("General failure cases", async function () {
    const { relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        firstDepositId,
        originChainId,
        destErc20.address
    )

      // Fees set too high.
      await expect(
        spokePool
          .connect(relayer)
          .fillRelay(
              relayData[0],
              relayData[1],
              relayData[2],
              toWei("0.51"),
              relayData[4],
              relayData[5],
              relayData[6],
              relayData[7],
              amountToRelay,
              repaymentChainId
          )
      ).to.be.reverted;
      await expect(
        spokePool
          .connect(relayer)
          .fillRelay(
              relayData[0],
              relayData[1],
              relayData[2],
              relayData[3],
              toWei("0.51"),
              relayData[5],
              relayData[6],
              relayData[7],
              amountToRelay,
              repaymentChainId
          )
      ).to.be.reverted;
      await expect(
        spokePool
          .connect(relayer)
          .fillRelay(
              relayData[0],
              relayData[1],
              relayData[2],
              toWei("0.5"),
              toWei("0.5"),
              relayData[5],
              relayData[6],
              relayData[7],
              amountToRelay,
              repaymentChainId
          )
      ).to.be.reverted;
  
      // Fill amount cannot be 0.
      await expect(
        spokePool
          .connect(relayer)
          .fillRelay(
              relayData[0],
              relayData[1],
              relayData[2],
              relayData[3],
              relayData[4],
              relayData[5],
              relayData[6],
              "0",
              amountToRelay,
              repaymentChainId
          )
      ).to.be.reverted;

      // Fill amount sends over relay amount
      await expect(
        spokePool
          .connect(relayer)
          .fillRelay(
              relayData[0],
              relayData[1],
              relayData[2],
              relayData[3],
              relayData[4],
              relayData[5],
              relayData[6],
              relayData[7],
              amountToDeposit, // Sending the total relay amount is invalid because this amount pre-fees would exceed 
              // the total relay amount.
              repaymentChainId
          )
      ).to.be.reverted;
  });
});
