import { expect, ethers, Contract, SignerWithAddress, hre, randomAddress } from "./utils";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";

let spokePool: Contract;
let owner: SignerWithAddress, rando: SignerWithAddress;

describe("SpokePool Upgrade Functions", async function () {
  beforeEach(async function () {
    [owner, rando] = await ethers.getSigners();
    ({ spokePool } = await spokePoolFixture());
  });
  it("Can upgrade", async function () {
    const spokePoolV2 = await hre.upgrades.deployImplementation(await ethers.getContractFactory("MockSpokePoolV2"), {
      kind: "uups",
    });
    const spokePoolV2Contract = (await ethers.getContractFactory("MockSpokePoolV2")).attach(spokePoolV2 as string);

    const newHubPool = randomAddress();
    const reinitializeData = await spokePoolV2Contract.populateTransaction.reinitialize(newHubPool);

    // Only owner can upgrade.
    await expect(spokePool.connect(rando).upgradeToAndCall(spokePoolV2, reinitializeData.data)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await spokePool.connect(owner).upgradeToAndCall(spokePoolV2, reinitializeData.data);

    // Hub pool should be changed.
    const spokePoolContract = (await ethers.getContractFactory("MockSpokePoolV2")).attach(spokePool.address);
    expect(await spokePoolContract.hubPool()).to.equal(newHubPool);

    // Contract should be an ERC20 now.
    expect(await spokePoolContract.totalSupply()).to.equal(0);

    // Can't reinitialize again.
    expect(spokePoolContract.reinitialize(newHubPool)).to.be.revertedWith(
      "Contract instance has already been initialized"
    );

    // Can call new function.
    expect(() => spokePool.emitEvent()).to.throw(/spokePool.emitEvent is not a function/);
    await expect(spokePoolContract.emitEvent()).to.emit(spokePoolContract, "NewEvent").withArgs(true);
  });
});
