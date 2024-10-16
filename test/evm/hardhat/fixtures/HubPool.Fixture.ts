import { getContractFactory, randomAddress, Contract, Signer } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { originChainId, bondAmount, refundProposalLiveness, finalFee } from "../constants";
import { repaymentChainId, finalFeeUsdc, TokenRolesEnum } from "../constants";
import { umaEcosystemFixture } from "./UmaEcosystem.Fixture";

export const hubPoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  return await deployHubPool(ethers);
});

export async function deployHubPool(ethers: any, spokePoolName = "MockSpokePool") {
  const [signer, crossChainAdmin] = await ethers.getSigners();

  // This fixture is dependent on the UMA ecosystem fixture. Run it first and grab the output. This is used in the
  // deployments that follows. The output is spread when returning contract instances from this fixture.
  const parentFixture = await umaEcosystemFixture();

  // Create 3 tokens: WETH for wrapping unwrapping and 2 ERC20s with different decimals.
  const weth = await (await getContractFactory("WETH9", signer)).deploy();
  const usdc = await (await getContractFactory("ExpandedERC20", signer)).deploy("USD Coin", "USDC", 6);
  await usdc.addMember(TokenRolesEnum.MINTER, signer.address);
  const dai = await (await getContractFactory("ExpandedERC20", signer)).deploy("DAI Stablecoin", "DAI", 18);
  await dai.addMember(TokenRolesEnum.MINTER, signer.address);
  const tokens = { weth, usdc, dai };

  // Set the above currencies as approved in the UMA collateralWhitelist.
  await parentFixture.collateralWhitelist.addToWhitelist(weth.address);
  await parentFixture.collateralWhitelist.addToWhitelist(usdc.address);
  await parentFixture.collateralWhitelist.addToWhitelist(dai.address);

  // Set the finalFee for all the new tokens.
  await parentFixture.store.setFinalFee(weth.address, { rawValue: finalFee });
  await parentFixture.store.setFinalFee(usdc.address, { rawValue: finalFeeUsdc });
  await parentFixture.store.setFinalFee(dai.address, { rawValue: finalFee });

  // Deploy the hubPool.
  const lpTokenFactory = await (await getContractFactory("LpTokenFactory", signer)).deploy();
  const hubPool = await (
    await getContractFactory("HubPool", signer)
  ).deploy(lpTokenFactory.address, parentFixture.finder.address, weth.address, parentFixture.timer.address);
  await hubPool.setBond(weth.address, bondAmount);
  await hubPool.setLiveness(refundProposalLiveness);

  // Deploy a mock chain adapter and add it as the chainAdapter for the test chainId. Set the SpokePool to address 0.
  const mockAdapter = await (await getContractFactory("Mock_Adapter", signer)).deploy();
  const mockSpoke = await hre.upgrades.deployProxy(
    await getContractFactory(spokePoolName, signer),
    [0, crossChainAdmin.address, hubPool.address],
    { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address] }
  );
  await hubPool.setCrossChainContracts(repaymentChainId, mockAdapter.address, mockSpoke.address);
  await hubPool.setCrossChainContracts(originChainId, mockAdapter.address, mockSpoke.address);

  // Deploy a new set of mocks for mainnet.
  const mainnetChainId = await hre.getChainId();
  const mockAdapterMainnet = await (await getContractFactory("Mock_Adapter", signer)).deploy();
  const mockSpokeMainnet = await hre.upgrades.deployProxy(
    await getContractFactory(spokePoolName, signer),
    [0, crossChainAdmin.address, hubPool.address],
    { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address] }
  );
  await hubPool.setCrossChainContracts(mainnetChainId, mockAdapterMainnet.address, mockSpokeMainnet.address);

  // Deploy mock l2 tokens for each token created before and whitelist the routes.
  const mockTokens = { l2Weth: randomAddress(), l2Dai: randomAddress(), l2Usdc: randomAddress() };

  // Whitelist pool rebalance routes but don't relay any messages to SpokePool
  await hubPool.setPoolRebalanceRoute(repaymentChainId, weth.address, mockTokens.l2Weth);
  await hubPool.setPoolRebalanceRoute(repaymentChainId, dai.address, mockTokens.l2Dai);
  await hubPool.setPoolRebalanceRoute(repaymentChainId, usdc.address, mockTokens.l2Usdc);

  return { ...tokens, ...mockTokens, hubPool, mockAdapter, mockSpoke, crossChainAdmin, ...parentFixture };
}

export async function enableTokensForLP(owner: Signer, hubPool: Contract, weth: Contract, tokens: Contract[]) {
  const lpTokens = [];
  for (const token of tokens) {
    await hubPool.enableL1TokenForLiquidityProvision(token.address);
    lpTokens.push(
      await (
        await getContractFactory("ExpandedERC20", owner)
      ).attach((await hubPool.callStatic.pooledTokens(token.address)).lpToken)
    );
  }
  return lpTokens;
}
