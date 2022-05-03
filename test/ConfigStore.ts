import { getContractFactory, SignerWithAddress, utf8ToHex, expect, Contract, ethers, randomAddress } from "./utils";
import * as constants from "./constants";

let configStore: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("Config Store", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    configStore = await (await getContractFactory("ConfigStore", owner)).deploy();
  });

  it("Updating rate model", async function () {
    const l1Token = randomAddress();
    const stringifiedRateModel = JSON.stringify(constants.sampleRateModel);
    await expect(configStore.connect(other).updateRateModel(l1Token, stringifiedRateModel)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(configStore.connect(owner).updateRateModel(l1Token, stringifiedRateModel))
      .to.emit(configStore, "UpdatedRateModel")
      .withArgs(l1Token, stringifiedRateModel);
    expect(await configStore.l1TokenRateModels(l1Token)).to.equal(stringifiedRateModel);
  });
  it("Updating token transfer threshold", async function () {
    const l1Token = randomAddress();
    await expect(
      configStore.connect(other).updateTransferThreshold(l1Token, constants.l1TokenTransferThreshold)
    ).to.be.revertedWith("Ownable: caller is not the owner");
    await expect(configStore.connect(owner).updateTransferThreshold(l1Token, constants.l1TokenTransferThreshold))
      .to.emit(configStore, "UpdatedTransferThreshold")
      .withArgs(l1Token, constants.l1TokenTransferThreshold.toString());
    expect(await configStore.l1TokenTransferThresholds(l1Token)).to.equal(constants.l1TokenTransferThreshold);
  });
  it("Updating global uint config", async function () {
    const key = utf8ToHex("MAX_POOL_REBALANCE_LEAF_SIZE");
    const value = constants.maxRefundsPerRelayerRefundLeaf;
    await expect(configStore.connect(other).updateUintGlobalConfig(key, value)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(configStore.connect(owner).updateUintGlobalConfig(key, value))
      .to.emit(configStore, "UpdatedGlobalConfig")
      .withArgs(key, value);
    expect(await configStore.uintGlobalConfig(key)).to.equal(value);
  });
});
