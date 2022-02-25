import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress } from "../utils";
import { getContractFactory, seedContract } from "../utils";
import { hubPoolFixture } from "../HubPool.Fixture";
import { buildRelayerRefundLeafs, buildRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, spokePool: Contract, timer: Contract, dai: Contract, weth: Contract;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, crossDomainAlias: SignerWithAddress;

async function constructSimpleTree(l2Token: Contract | string, destinationChainId: number) {
  const leafs = buildRelayerRefundLeafs(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]] // refundAmounts.
  );

  const tree = await buildRelayerRefundTree(leafs);

  return { leafs, tree };
}
describe("Ethereum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, hubPool, timer } = await hubPoolFixture());

    spokePool = await (
      await getContractFactory("Ethereum_SpokePool", { signer: owner })
    ).deploy(hubPool.address, weth.address, timer.address);

    // Seed spoke pool with tokens that it should transfer to the hub pool
    // via the _bridgeTokensToHubPool() internal call.
    await seedContract(spokePool, relayer, [dai], weth, amountHeldByPool);
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

  it("Only owner can set the quote time buffer", async function () {
    await expect(spokePool.connect(rando).setDepositQuoteTimeBuffer(12345)).to.be.reverted;
    await spokePool.connect(owner).setDepositQuoteTimeBuffer(12345);
    expect(await spokePool.depositQuoteTimeBuffer()).to.equal(12345);
  });

  it("Only owner can initialize a relayer refund", async function () {
    await expect(spokePool.connect(rando).relayRootBundle(mockTreeRoot, mockTreeRoot)).to.be.reverted;
    await spokePool.connect(owner).relayRootBundle(mockTreeRoot, mockTreeRoot);
    expect((await spokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await spokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Bridge tokens to hub pool correctly sends tokens to hub pool", async function () {
    const { leafs, tree } = await constructSimpleTree(dai.address, await spokePool.callStatic.chainId());
    await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    expect(
      await spokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    ).to.changeTokenBalances(dai, [spokePool, hubPool], [amountToReturn.mul(-1), amountToReturn]);
  });
});
