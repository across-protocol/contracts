import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, seedWallet, toBN, toWei } from "./utils";
import { deploySpokePoolTestHelperContracts, enableRoutes, getRelayHash } from "./SpokePool.Fixture";
import { amountToSeedWallets, amountToDeposit, amountToRelay, amountToRelayNetFees } from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;

describe.only("SpokePool Relayer Logic", async function () {
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
  it("Relaying ERC20 tokens correctly pulls tokens net fees and changes contract state", async function () {
    const { relayHash, relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        0, // deposit ID
        666, // origin chain ID
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
            amountToRelay, // Assumed to be < amountToDeposit
            777 // repayment chain ID
        )
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        amountToRelay,
        777,
        amountToRelayNetFees,
        relayer.address,
        relayData
      );

    // The collateral should have transferred from relayer to recipient.
    expect(await destErc20.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelayNetFees));
    expect(await destErc20.balanceOf(recipient.address)).to.equal(amountToRelayNetFees);

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelay);
  });
  it("Relaying WETH correctly unwraps into ETH", async function () {
    const { relayHash, relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        0, // deposit ID
        666, // origin chain ID
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
            amountToRelay, // Assumed to be < amountToDeposit
            777 // repayment chain ID
        )
    )
      .to.emit(spokePool, "FilledRelay")
      .withArgs(
        relayHash,
        amountToRelay,
        777,
        amountToRelayNetFees,
        relayer.address,
        relayData
      );

    // The collateral should have unwrapped to ETH and then transferred to recipient.
    expect(await weth.balanceOf(relayer.address)).to.equal(amountToSeedWallets.sub(amountToRelayNetFees));
    expect(await recipient.getBalance()).to.equal(startingRecipientBalance.add(amountToRelayNetFees));

    // Fill amount should be set.
    expect(await spokePool.relayFills(relayHash)).to.equal(amountToRelay);
  });
  it("General failure cases", async function () {
    const { relayData } = getRelayHash(
        depositor.address,
        recipient.address,
        0, // deposit ID
        666, // origin chain ID
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
              777
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
              777
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
              777
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
              toBN(relayData[7]).mul(toBN("2")), // Fill > amount to relay
              777
          )
      ).to.be.reverted;
  });
});
