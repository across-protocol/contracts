import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress } from "./utils";
import { spokePoolFixture } from "./SpokePool.Fixture";
import { spokePoolRelayerRefundRoot, spokePoolRelayerRefundRootDefaultId } from "./constants";

let spokePool: Contract;
let caller: SignerWithAddress;

describe.only("SpokePool Initialize Relayer Refund Logic", async function () {
  beforeEach(async function () {
    [caller] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Initializing root stores root and emits event", async function () {
    await expect(spokePool.connect(caller).initializeRelayerRefund(spokePoolRelayerRefundRoot))
      .to.emit(spokePool, "InitializedRelayerRefund")
      .withArgs(spokePoolRelayerRefundRootDefaultId, spokePoolRelayerRefundRoot);
    expect(await spokePool.relayerRefunds(spokePoolRelayerRefundRootDefaultId)).to.equal(spokePoolRelayerRefundRoot);
  });
});
