import { getContractFactory, SignerWithAddress, utf8ToHex, expect, Contract, ethers, randomAddress } from "./utils";
import * as constants from "./constants";

let tokenConfigStore: Contract, globalConfigStore: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("Config Store", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    tokenConfigStore = await (await getContractFactory("TokenConfigStore", owner)).deploy();
    globalConfigStore = await (await getContractFactory("GlobalConfigStore", owner)).deploy();
  });

  it("Updating rate model", async function () {
    const l1Token = randomAddress();
    const stringifiedRateModel = JSON.stringify(constants.sampleRateModel);
    await expect(tokenConfigStore.connect(other).updateRateModel(l1Token, stringifiedRateModel)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(tokenConfigStore.connect(owner).updateRateModel(l1Token, stringifiedRateModel))
      .to.emit(tokenConfigStore, "UpdatedRateModel")
      .withArgs(l1Token, stringifiedRateModel);
    expect(await tokenConfigStore.l1TokenRateModels(l1Token)).to.equal(stringifiedRateModel);
  });
  it("Updating token transfer threshold", async function () {
    const l1Token = randomAddress();
    await expect(
      tokenConfigStore.connect(other).updateTransferThreshold(l1Token, constants.l1TokenTransferThreshold)
    ).to.be.revertedWith("Ownable: caller is not the owner");
    await expect(tokenConfigStore.connect(owner).updateTransferThreshold(l1Token, constants.l1TokenTransferThreshold))
      .to.emit(tokenConfigStore, "UpdatedTransferThreshold")
      .withArgs(l1Token, constants.l1TokenTransferThreshold.toString());
    expect(await tokenConfigStore.l1TokenTransferThresholds(l1Token)).to.equal(constants.l1TokenTransferThreshold);
  });
  it("Updating global config", async function () {
    const key = utf8ToHex("MAX_POOL_REBALANCE_LEAF_SIZE");
    const value = constants.maxRefundsPerRelayerRefundLeaf.toString();
    await expect(globalConfigStore.connect(other).updateGlobalConfig(key, value)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(globalConfigStore.connect(owner).updateGlobalConfig(key, value))
      .to.emit(globalConfigStore, "UpdatedGlobalConfig")
      .withArgs(key, value);
    expect(await globalConfigStore.globalConfig(key)).to.equal(value);
  });
});
