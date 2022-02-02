import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { depositDestinationChainId } from "./constants";

let spokePool: Contract, erc20: Contract;
let owner: SignerWithAddress;

describe("SpokePool Admin Functions", async function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ spokePool, erc20 } = await spokePoolFixture());
  });
  it("Enable token path", async function () {
    await expect(spokePool.connect(owner).setEnableRoute(erc20.address, depositDestinationChainId, true))
      .to.emit(spokePool, "EnabledDepositRoute")
      .withArgs(erc20.address, depositDestinationChainId, true);
    expect(await spokePool.enabledDepositRoutes(erc20.address, depositDestinationChainId)).to.equal(true);
  });
  it("Change deposit quote buffer", async function () {
    await expect(spokePool.connect(owner).setDepositQuoteTimeBuffer(60))
      .to.emit(spokePool, "SetDepositQuoteTimeBuffer")
      .withArgs(60);

    expect(await spokePool.depositQuoteTimeBuffer()).to.equal(60);
  });
});
