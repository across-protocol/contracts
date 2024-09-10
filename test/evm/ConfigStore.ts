import {
  getContractFactory,
  SignerWithAddress,
  utf8ToHex,
  expect,
  Contract,
  ethers,
  randomAddress,
} from "../../utils/utils";
import * as constants from "./constants";

let configStore: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("Config Store", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    configStore = await (await getContractFactory("AcrossConfigStore", owner)).deploy();
  });

  it("Updating token config", async function () {
    const l1Token = randomAddress();
    const value = JSON.stringify({
      rateModel: constants.sampleRateModel,
      tokenTransferThreshold: constants.l1TokenTransferThreshold,
    });
    await expect(configStore.connect(other).updateTokenConfig(l1Token, value)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(configStore.connect(owner).updateTokenConfig(l1Token, value))
      .to.emit(configStore, "UpdatedTokenConfig")
      .withArgs(l1Token, value);
    expect(await configStore.l1TokenConfig(l1Token)).to.equal(value);
  });
  it("Updating global config", async function () {
    const key = utf8ToHex("MAX_POOL_REBALANCE_LEAF_SIZE");
    const value = constants.maxRefundsPerRelayerRefundLeaf.toString();
    await expect(configStore.connect(other).updateGlobalConfig(key, value)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await expect(configStore.connect(owner).updateGlobalConfig(key, value))
      .to.emit(configStore, "UpdatedGlobalConfig")
      .withArgs(key, value);
    expect(await configStore.globalConfig(key)).to.equal(value);
  });
});
