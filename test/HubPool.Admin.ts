import { getContractFactory, SignerWithAddress, seedWallet, expect } from "./utils";
import { Contract, ethers, randomAddress, utf8ToHex } from "./utils";
import { originChainId, destinationChainId, bondAmount, zeroAddress, mockTreeRoot } from "./constants";
import { mockSlowRelayRoot, finalFeeUsdc, finalFee, totalBond } from "./constants";
import { hubPoolFixture } from "./fixtures/HubPool.Fixture";
import { ZERO_ADDRESS } from "@uma/common";

let hubPool: Contract,
  weth: Contract,
  usdc: Contract,
  mockSpoke: Contract,
  mockAdapter: Contract,
  identifierWhitelist: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;

describe("HubPool Admin functions", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    ({ weth, hubPool, usdc, mockAdapter, mockSpoke, identifierWhitelist } = await hubPoolFixture());
  });

  it("Can add L1 token to whitelisted lpTokens mapping", async function () {
    expect((await hubPool.callStatic.pooledTokens(weth.address)).lpToken).to.equal(zeroAddress);
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);

    const pooledTokenStruct = await hubPool.callStatic.pooledTokens(weth.address);
    expect(pooledTokenStruct.lpToken).to.not.equal(zeroAddress);
    expect(pooledTokenStruct.isEnabled).to.equal(true);
    expect(pooledTokenStruct.lastLpFeeUpdate).to.equal(Number(await hubPool.getCurrentTime()));

    const lpToken = await (await getContractFactory("ExpandedERC20", owner)).attach(pooledTokenStruct.lpToken);
    expect(await lpToken.callStatic.symbol()).to.equal("Av2-WETH-LP");
    expect(await lpToken.callStatic.name()).to.equal("Across Wrapped Ether LP Token");
  });
  it("Only owner can enable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Can disable L1 Tokens for liquidity provision", async function () {
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);
    const pooledTokenStruct = await hubPool.callStatic.pooledTokens(weth.address);
    const lpToken = pooledTokenStruct.lpToken;
    const lastLpFeeUpdate = pooledTokenStruct.lastLpFeeUpdate;

    await hubPool.disableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(false);

    // Can re-enable the L1 token now without creating a new LP token or resetting timestamp.
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).lpToken).to.equal(lpToken);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).lastLpFeeUpdate).to.equal(lastLpFeeUpdate);
  });
  it("Only owner can disable L1 Tokens for liquidity provision", async function () {
    await expect(hubPool.connect(other).disableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
  });
  it("Only owner can set cross chain contract helpers", async function () {
    await expect(
      hubPool.connect(other).setCrossChainContracts(destinationChainId, mockAdapter.address, mockSpoke.address)
    ).to.be.reverted;
  });
  it("Only owner can relay spoke pool admin message", async function () {
    const functionData = mockSpoke.interface.encodeFunctionData("setEnableRoute", [
      weth.address,
      randomAddress(),
      destinationChainId,
      false,
    ]);
    await expect(hubPool.connect(other).relaySpokePoolAdminFunction(destinationChainId, functionData)).to.be.reverted;

    // Cannot relay admin function if spoke pool is set to zero address.
    await hubPool.setCrossChainContracts(destinationChainId, mockAdapter.address, ZERO_ADDRESS);
    await expect(hubPool.relaySpokePoolAdminFunction(destinationChainId, functionData)).to.be.reverted;
    await hubPool.setCrossChainContracts(destinationChainId, mockAdapter.address, mockSpoke.address);
    await expect(hubPool.relaySpokePoolAdminFunction(destinationChainId, functionData))
      .to.emit(hubPool, "SpokePoolAdminFunctionTriggered")
      .withArgs(destinationChainId, functionData);
  });
  it("Only owner can whitelist route for deposits and rebalances", async function () {
    await hubPool.setCrossChainContracts(destinationChainId, mockAdapter.address, mockSpoke.address);
    await expect(hubPool.connect(other).setPoolRebalanceRoute(destinationChainId, weth.address, usdc.address)).to.be
      .reverted;
    await expect(hubPool.setPoolRebalanceRoute(destinationChainId, weth.address, usdc.address))
      .to.emit(hubPool, "SetPoolRebalanceRoute")
      .withArgs(destinationChainId, weth.address, usdc.address);

    // Relay deposit mapping to spoke pool. Check content of messages sent to mock spoke pool.
    await expect(
      hubPool.connect(other).setDepositRoute(originChainId, destinationChainId, weth.address, usdc.address, true)
    ).to.be.reverted;
    await expect(hubPool.setDepositRoute(originChainId, destinationChainId, weth.address, usdc.address, true))
      .to.emit(hubPool, "SetEnableDepositRoute")
      .withArgs(originChainId, destinationChainId, weth.address, usdc.address, true);

    // Disable deposit route on SpokePool right after:
    await hubPool.setDepositRoute(originChainId, destinationChainId, weth.address, usdc.address, false);

    // Since the mock adapter is delegatecalled, when querying, its address should be the hubPool address.
    const mockAdapterAtHubPool = mockAdapter.attach(hubPool.address);
    const relayMessageEvents = await mockAdapterAtHubPool.queryFilter(
      mockAdapterAtHubPool.filters.RelayMessageCalled()
    );
    expect(relayMessageEvents[relayMessageEvents.length - 1].args?.message).to.equal(
      mockSpoke.interface.encodeFunctionData("setEnableRoute", [
        weth.address,
        usdc.address,
        destinationChainId,
        false, // Latest call disabled the route
      ])
    );
    expect(relayMessageEvents[relayMessageEvents.length - 2].args?.message).to.equal(
      mockSpoke.interface.encodeFunctionData("setEnableRoute", [
        weth.address,
        usdc.address,
        destinationChainId,
        true, // Second to last call enabled the route
      ])
    );
  });

  it("Can change the bond token and amount", async function () {
    expect(await hubPool.callStatic.bondToken()).to.equal(weth.address); // Default set in the fixture.
    expect(await hubPool.callStatic.bondAmount()).to.equal(bondAmount.add(finalFee)); // Default set in the fixture.

    // Set the bond token and amount to 1000 USDC
    const newBondAmount = ethers.utils.parseUnits("1000", 6); // set to 1000e6, i.e 1000 USDC.
    await hubPool.setBond(usdc.address, newBondAmount);

    expect(await hubPool.callStatic.bondToken()).to.equal(usdc.address); // New Address.
    expect(await hubPool.callStatic.bondAmount()).to.equal(newBondAmount.add(finalFeeUsdc)); // New Bond amount.
  });
  it("Can not change the bond token and amount during a pending refund", async function () {
    await seedWallet(owner, [], weth, totalBond);
    await weth.approve(hubPool.address, totalBond);
    await hubPool.proposeRootBundle([1, 2, 3], 5, mockTreeRoot, mockTreeRoot, mockSlowRelayRoot);
    await expect(hubPool.setBond(usdc.address, "1")).to.be.revertedWith("proposal has unclaimed leafs");
  });
  it("Cannot change bond token to unwhitelisted token", async function () {
    await expect(hubPool.setBond(randomAddress(), "1")).to.be.revertedWith("Not on whitelist");
  });
  it("Only owner can set bond", async function () {
    await expect(hubPool.connect(other).setBond(usdc.address, "1")).to.be.reverted;
  });
  it("Set identifier", async function () {
    const identifier = utf8ToHex("TEST_ID");
    await identifierWhitelist.addSupportedIdentifier(identifier);
    await hubPool.connect(owner).setIdentifier(identifier);
    expect(await hubPool.identifier()).to.equal(identifier);
  });
  it("Only owner can set identifier", async function () {
    const identifier = utf8ToHex("TEST_ID");
    await identifierWhitelist.addSupportedIdentifier(identifier);
    await expect(hubPool.connect(other).setIdentifier(identifier)).to.be.reverted;
  });
  it("Only whitelisted identifiers allowed", async function () {
    const identifier = utf8ToHex("TEST_ID");
    await expect(hubPool.connect(owner).setIdentifier(identifier)).to.be.revertedWith("Identifier not supported");
  });
  it("Set liveness", async function () {
    const newLiveness = 1000000;
    await hubPool.connect(owner).setLiveness(newLiveness);
    await expect(await hubPool.liveness()).to.equal(newLiveness);
  });
  it("Liveness too short", async function () {
    await expect(hubPool.connect(owner).setLiveness(599)).to.be.revertedWith("Liveness too short");
  });
  it("Only owner can set liveness", async function () {
    await expect(hubPool.connect(other).setLiveness(1000000)).to.be.reverted;
  });
  it("Only owner can pause", async function () {
    await expect(hubPool.connect(other).setPaused(true)).to.be.reverted;
    await expect(hubPool.connect(owner).setPaused(true)).to.emit(hubPool, "Paused").withArgs(true);
  });
  it("Emergency deletion clears the rootBundleProposal", async function () {
    await seedWallet(owner, [], weth, totalBond);
    await weth.approve(hubPool.address, totalBond);
    await hubPool.proposeRootBundle([1, 2, 3], 5, mockTreeRoot, mockTreeRoot, mockSlowRelayRoot);
    expect(await hubPool.rootBundleProposal()).to.have.property("poolRebalanceRoot", mockTreeRoot);
    expect(await hubPool.rootBundleProposal()).to.have.property("unclaimedPoolRebalanceLeafCount", 5);
    await expect(() => hubPool.connect(owner).emergencyDeleteProposal()).to.changeTokenBalances(
      weth,
      [owner, hubPool],
      [totalBond, totalBond.mul(-1)]
    );
    expect(await hubPool.rootBundleProposal()).to.have.property(
      "poolRebalanceRoot",
      ethers.utils.hexZeroPad("0x0", 32)
    );
    expect(await hubPool.rootBundleProposal()).to.have.property("unclaimedPoolRebalanceLeafCount", 0);
  });
  it("Emergency deletion can only be called by owner", async function () {
    await seedWallet(owner, [], weth, totalBond);
    await weth.approve(hubPool.address, totalBond);
    await expect(hubPool.connect(other).emergencyDeleteProposal()).to.be.reverted;
    await expect(hubPool.connect(owner).emergencyDeleteProposal()).to.not.be.reverted;
  });
});
