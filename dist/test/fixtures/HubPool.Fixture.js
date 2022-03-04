"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.enableTokensForLP = exports.hubPoolFixture = void 0;
const common_1 = require("@uma/common");
const utils_1 = require("../utils");
const constants_1 = require("../constants");
const constants_2 = require("../constants");
const UmaEcosystem_Fixture_1 = require("./UmaEcosystem.Fixture");
exports.hubPoolFixture = utils_1.hre.deployments.createFixture(async ({ ethers }) => {
  const [signer, crossChainAdmin] = await ethers.getSigners();
  // This fixture is dependent on the UMA ecosystem fixture. Run it first and grab the output. This is used in the
  // deployments that follows. The output is spread when returning contract instances from this fixture.
  const parentFixture = await (0, UmaEcosystem_Fixture_1.umaEcosystemFixture)();
  // Create 3 tokens: WETH for wrapping unwrapping and 2 ERC20s with different decimals.
  const weth = await (await (0, utils_1.getContractFactory)("WETH9", signer)).deploy();
  const usdc = await (await (0, utils_1.getContractFactory)("ExpandedERC20", signer)).deploy("USD Coin", "USDC", 6);
  await usdc.addMember(common_1.TokenRolesEnum.MINTER, signer.address);
  const dai = await (
    await (0, utils_1.getContractFactory)("ExpandedERC20", signer)
  ).deploy("DAI Stablecoin", "DAI", 18);
  await dai.addMember(common_1.TokenRolesEnum.MINTER, signer.address);
  const tokens = { weth, usdc, dai };
  // Set the above currencies as approved in the UMA collateralWhitelist.
  await parentFixture.collateralWhitelist.addToWhitelist(weth.address);
  await parentFixture.collateralWhitelist.addToWhitelist(usdc.address);
  await parentFixture.collateralWhitelist.addToWhitelist(dai.address);
  // Set the finalFee for all the new tokens.
  await parentFixture.store.setFinalFee(weth.address, { rawValue: constants_1.finalFee });
  await parentFixture.store.setFinalFee(usdc.address, { rawValue: constants_2.finalFeeUsdc });
  await parentFixture.store.setFinalFee(dai.address, { rawValue: constants_1.finalFee });
  // Deploy the hubPool.
  const lpTokenFactory = await (await (0, utils_1.getContractFactory)("LpTokenFactory", signer)).deploy();
  const hubPool = await (
    await (0, utils_1.getContractFactory)("HubPool", { signer: signer })
  ).deploy(lpTokenFactory.address, parentFixture.finder.address, weth.address, parentFixture.timer.address);
  await hubPool.setBond(weth.address, constants_1.bondAmount);
  await hubPool.setLiveness(constants_1.refundProposalLiveness);
  // Deploy a mock chain adapter and add it as the chainAdapter for the test chainId. Set the SpokePool to address 0.
  const mockAdapter = await (await (0, utils_1.getContractFactory)("Mock_Adapter", signer)).deploy();
  const mockSpoke = await (
    await (0, utils_1.getContractFactory)("MockSpokePool", { signer: signer })
  ).deploy(crossChainAdmin.address, hubPool.address, weth.address, parentFixture.timer.address);
  await hubPool.setCrossChainContracts(constants_2.repaymentChainId, mockAdapter.address, mockSpoke.address);
  await hubPool.setCrossChainContracts(constants_1.originChainId, mockAdapter.address, mockSpoke.address);
  // Deploy a new set of mocks for mainnet.
  const mainnetChainId = await utils_1.hre.getChainId();
  const mockAdapterMainnet = await (await (0, utils_1.getContractFactory)("Mock_Adapter", signer)).deploy();
  const mockSpokeMainnet = await (
    await (0, utils_1.getContractFactory)("MockSpokePool", { signer: signer })
  ).deploy(crossChainAdmin.address, hubPool.address, weth.address, parentFixture.timer.address);
  await hubPool.setCrossChainContracts(mainnetChainId, mockAdapterMainnet.address, mockSpokeMainnet.address);
  // Deploy mock l2 tokens for each token created before and whitelist the routes.
  const mockTokens = {
    l2Weth: (0, utils_1.randomAddress)(),
    l2Dai: (0, utils_1.randomAddress)(),
    l2Usdc: (0, utils_1.randomAddress)(),
  };
  await hubPool.whitelistRoute(
    constants_1.originChainId,
    constants_2.repaymentChainId,
    weth.address,
    mockTokens.l2Weth
  );
  await hubPool.whitelistRoute(constants_1.originChainId, constants_2.repaymentChainId, dai.address, mockTokens.l2Dai);
  await hubPool.whitelistRoute(
    constants_1.originChainId,
    constants_2.repaymentChainId,
    usdc.address,
    mockTokens.l2Usdc
  );
  await hubPool.whitelistRoute(mainnetChainId, constants_2.repaymentChainId, weth.address, mockTokens.l2Weth);
  await hubPool.whitelistRoute(mainnetChainId, constants_2.repaymentChainId, dai.address, mockTokens.l2Dai);
  await hubPool.whitelistRoute(mainnetChainId, constants_2.repaymentChainId, usdc.address, mockTokens.l2Usdc);
  return { ...tokens, ...mockTokens, hubPool, mockAdapter, mockSpoke, crossChainAdmin, ...parentFixture };
});
async function enableTokensForLP(owner, hubPool, weth, tokens) {
  const lpTokens = [];
  for (const token of tokens) {
    await hubPool.enableL1TokenForLiquidityProvision(token.address);
    lpTokens.push(
      await (
        await (0, utils_1.getContractFactory)("ExpandedERC20", owner)
      ).attach((await hubPool.callStatic.pooledTokens(token.address)).lpToken)
    );
  }
  return lpTokens;
}
exports.enableTokensForLP = enableTokensForLP;
