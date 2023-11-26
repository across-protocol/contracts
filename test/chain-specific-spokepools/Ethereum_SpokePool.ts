import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, SignerWithAddress, getContractFactory, seedContract } from "../../utils/utils";
import { hre } from "../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, spokePool: Contract, dai: Contract, weth: Contract;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

describe("Ethereum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, hubPool } = await hubPoolFixture());

    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Ethereum_SpokePool", owner),
      [0, hubPool.address],
      { kind: "uups", unsafeAllow: ["delegatecall"] }
    );

    // Seed spoke pool with tokens that it should transfer to the hub pool
    // via the _bridgeTokensToHubPool() internal call.
    await seedContract(spokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("Ethereum_SpokePool", owner),
      { kind: "uups", unsafeAllow: ["delegatecall"] }
    );

    // upgradeTo fails unless called by cross domain admin
    await expect(spokePool.connect(rando).upgradeTo(implementation)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
    await spokePool.connect(owner).upgradeTo(implementation);
  });

  it("Only owner can set the cross domain admin", async function () {
    await expect(spokePool.connect(rando).setCrossDomainAdmin(rando.address)).to.be.reverted;
    await spokePool.connect(owner).setCrossDomainAdmin(rando.address);
    expect(await spokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Only owner can enable a route", async function () {
    await expect(spokePool.connect(rando).setEnableRoute(dai.address, 1, true)).to.be.reverted;
    await spokePool.connect(owner).setEnableRoute(dai.address, 1, true);
    expect(await spokePool.enabledDepositRoutes(dai.address, 1)).to.equal(true);
  });

  it("Only owner can set the hub pool address", async function () {
    await expect(spokePool.connect(rando).setHubPool(rando.address)).to.be.reverted;
    await spokePool.connect(owner).setHubPool(rando.address);
    expect(await spokePool.hubPool()).to.equal(rando.address);
  });

  it("Only owner can initialize a relayer refund", async function () {
    await expect(spokePool.connect(rando).relayRootBundle(mockTreeRoot, mockTreeRoot)).to.be.reverted;
    await spokePool.connect(owner).relayRootBundle(mockTreeRoot, mockTreeRoot);
    expect((await spokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await spokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Only owner can delete a relayer refund", async function () {
    await spokePool.connect(owner).relayRootBundle(mockTreeRoot, mockTreeRoot);
    await expect(spokePool.connect(rando).emergencyDeleteRootBundle(0)).to.be.reverted;
    await expect(spokePool.connect(owner).emergencyDeleteRootBundle(0)).to.not.be.reverted;
    expect((await spokePool.rootBundles(0)).slowRelayRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
    expect((await spokePool.rootBundles(0)).relayerRefundRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
  });

  it("Bridge tokens to hub pool correctly sends tokens to hub pool", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(dai.address, await spokePool.callStatic.chainId());
    await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await expect(() =>
      spokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.changeTokenBalances(dai, [spokePool, hubPool], [amountToReturn.mul(-1), amountToReturn]);
  });
});
