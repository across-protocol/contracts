import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress } from "./utils";
import { ZERO_ADDRESS } from "@uma/common";
import { deploySpokePoolTestHelperContracts } from "./SpokePool.Fixture";
import { depositDestinationChainId } from "./constants";

let spokePool: Contract, erc20: Contract;
let admin: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [admin] = await ethers.getSigners();
    ({ spokePool, erc20 } = await deploySpokePoolTestHelperContracts(admin));
  });
  it("Whitelist token path", async function() {
    // Cannot set spoke pool to zero address.
    await expect(spokePool
        .connect(admin)
        .whitelistRoute(
          erc20.address,
          erc20.address,
          ZERO_ADDRESS,
          true,
          depositDestinationChainId
        )).to.be.reverted;

    await expect(spokePool
      .connect(admin)
      .whitelistRoute(
        erc20.address,
        erc20.address,
        spokePool.address,
        true,
        depositDestinationChainId
      )).to.emit(spokePool, "WhitelistRoute").withArgs(
        erc20.address,
        depositDestinationChainId,
        erc20.address,
        spokePool.address,
        true
      );

    // Whitelisted path should be saved in contract.
    const whitelistedDestinationRoutes = await spokePool.whitelistedDestinationRoutes(erc20.address, depositDestinationChainId)
    expect(whitelistedDestinationRoutes.token).to.equal(erc20.address)
    expect(whitelistedDestinationRoutes.spokePool).to.equal(spokePool.address)
    expect(whitelistedDestinationRoutes.isWethToken).to.equal(true)
    expect(whitelistedDestinationRoutes.depositsEnabled).to.equal(true)
  });
  it("Enable/Disable deposits", async function() {
      // Must whitelist token first before disabling deposits.
      await expect(spokePool
        .connect(admin)
        .setEnableDeposits(
          erc20.address,
          depositDestinationChainId,
          false
        )).to.be.reverted;

    await spokePool.whitelistRoute(
        erc20.address,
        erc20.address,
        spokePool.address,
        true,
        depositDestinationChainId
      );
    await expect(spokePool
      .connect(admin)
      .setEnableDeposits(
        erc20.address,
        depositDestinationChainId,
        false
      )).to.emit(spokePool, "DepositsEnabled").withArgs(
        erc20.address,
        depositDestinationChainId,
        false
      );

    // Whitelisted path entry should be updated
    const whitelistedDestinationRoutes = await spokePool.whitelistedDestinationRoutes(erc20.address, depositDestinationChainId)
    expect(whitelistedDestinationRoutes.depositsEnabled).to.equal(false)
  });
});
