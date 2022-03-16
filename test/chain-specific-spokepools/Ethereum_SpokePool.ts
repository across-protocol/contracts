import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, SignerWithAddress } from "../utils";
import { getContractFactory, seedContract } from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, spokePool: Contract, timer: Contract, dai: Contract, weth: Contract, l2Dai: string;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

describe("Ethereum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, hubPool, timer, l2Dai } = await hubPoolFixture());

    spokePool = await (
      await getContractFactory("Ethereum_SpokePool", owner)
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
    await expect(spokePool.connect(rando).setEnableRoute(l2Dai, dai.address, 1, true)).to.be.reverted;
    await spokePool.connect(owner).setEnableRoute(l2Dai, dai.address, 1, true);
    const destinationTokenStruct = await spokePool.enabledDepositRoutes(l2Dai, 1);
    expect(destinationTokenStruct.enabled).to.equal(true);
    expect(destinationTokenStruct.destinationToken).to.equal(dai.address);
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

  it("Only owner can delete a relayer refund", async function () {
    await spokePool.connect(owner).relayRootBundle(mockTreeRoot, mockTreeRoot);
    await expect(spokePool.connect(rando).emergencyDeleteRootBundle(0)).to.be.reverted;
    await expect(spokePool.connect(owner).emergencyDeleteRootBundle(0)).to.not.be.reverted;
    expect((await spokePool.rootBundles(0)).slowRelayRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
    expect((await spokePool.rootBundles(0)).relayerRefundRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
  });

  it("Bridge tokens to hub pool correctly sends tokens to hub pool", async function () {
    const { leafs, tree } = await constructSingleRelayerRefundTree(dai.address, await spokePool.callStatic.chainId());
    await spokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await expect(() =>
      spokePool.connect(relayer).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    ).to.changeTokenBalances(dai, [spokePool, hubPool], [amountToReturn.mul(-1), amountToReturn]);
  });
});
