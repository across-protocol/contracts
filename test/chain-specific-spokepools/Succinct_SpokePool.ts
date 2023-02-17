import { ethers, expect, Contract, SignerWithAddress, getContractFactory, hre } from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";

let succinctSpokePool: Contract, timer: Contract, weth: Contract;

let owner: SignerWithAddress,
  succinctTargetAmb: SignerWithAddress,
  rando: SignerWithAddress,
  hubPool: SignerWithAddress;
const l1ChainId = 45;

describe("Succinct Spoke Pool", function () {
  beforeEach(async function () {
    [hubPool, succinctTargetAmb, rando] = await ethers.getSigners();
    ({ timer, weth } = await hubPoolFixture());

    succinctSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Succinct_SpokePool", owner),
      [l1ChainId, succinctTargetAmb.address, 0, hubPool.address, hubPool.address, weth.address],
      { kind: "uups" }
    );
  });

  it("Only correct caller can set the cross domain admin", async function () {
    // Cannot call directly
    await expect(succinctSpokePool.connect(rando).setCrossDomainAdmin(rando.address)).to.be.reverted;

    const setCrossDomainAdminData = succinctSpokePool.interface.encodeFunctionData("setCrossDomainAdmin", [
      rando.address,
    ]);

    // Wrong origin chain id address.
    await expect(
      succinctSpokePool.connect(succinctTargetAmb).handleTelepathy(44, hubPool.address, setCrossDomainAdminData)
    ).to.be.reverted;

    // Wrong rootMessageSender address.
    await expect(
      succinctSpokePool.connect(succinctTargetAmb).handleTelepathy(l1ChainId, rando.address, setCrossDomainAdminData)
    ).be.reverted;

    // Wrong calling address.
    await expect(succinctSpokePool.connect(rando).handleTelepathy(l1ChainId, hubPool.address, setCrossDomainAdminData))
      .to.be.reverted;

    await succinctSpokePool
      .connect(succinctTargetAmb)
      .handleTelepathy(l1ChainId, hubPool.address, setCrossDomainAdminData);
    expect(await succinctSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Can upgrade succinct target AMB", async function () {
    // Cannot call directly
    await expect(succinctSpokePool.connect(rando).setSuccinctTargetAmb(rando.address)).to.be.reverted;
    await expect(succinctSpokePool.connect(succinctTargetAmb).setSuccinctTargetAmb(rando.address)).to.be.reverted;
    await expect(succinctSpokePool.connect(hubPool).setSuccinctTargetAmb(rando.address)).to.be.reverted;

    const setSuccinctTargetAmb = succinctSpokePool.interface.encodeFunctionData("setSuccinctTargetAmb", [
      rando.address,
    ]);

    await succinctSpokePool
      .connect(succinctTargetAmb)
      .handleTelepathy(l1ChainId, hubPool.address, setSuccinctTargetAmb);
    expect(await succinctSpokePool.succinctTargetAmb()).to.equal(rando.address);
  });
});
