import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress } from "./utils";
import { deploySpokePoolTestHelperContracts } from "./SpokePool.Fixture";
import { depositDestinationChainId } from "./constants";

let spokePool: Contract, erc20: Contract;
let owner: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ spokePool, erc20 } = await deploySpokePoolTestHelperContracts(owner));
  });
  it("Whitelist token path", async function () {
    await expect(spokePool.connect(owner).whitelistRoute(erc20.address, erc20.address, depositDestinationChainId))
      .to.emit(spokePool, "WhitelistRoute")
      .withArgs(erc20.address, depositDestinationChainId, erc20.address);

    // Whitelisted path should be saved in contract.
    expect(await spokePool.whitelistedDestinationRoutes(erc20.address, depositDestinationChainId)).to.equal(
      erc20.address
    );
  });
  it("Change deposit quote buffer", async function () {
    await expect(spokePool.connect(owner).setDepositQuoteTimeBuffer(60))
      .to.emit(spokePool, "SetDepositQuoteTimeBuffer")
      .withArgs(60);

    expect(await spokePool.depositQuoteTimeBuffer()).to.equal(60);
  });
});
