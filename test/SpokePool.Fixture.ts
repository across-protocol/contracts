import { TokenRolesEnum } from "@uma/common";
import { Contract } from "ethers";
import { getContractFactory, SignerWithAddress } from "./utils";
import { depositDestinationChainId, depositQuoteTimeBuffer } from "./constants";

export async function deploySpokePoolTestHelperContracts(deployerWallet: SignerWithAddress) {
  // Useful contracts.
  const timer = await (await getContractFactory("Timer", deployerWallet)).deploy();

  // Create tokens:
  const weth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const erc20 = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("USD Coin", "USDC", 18);
  await erc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);
  const unwhitelistedErc20 = await (
    await getContractFactory("ExpandedERC20", deployerWallet)
  ).deploy("Unwhitelisted", "UNWHITELISTED", 18);
  await unwhitelistedErc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the pool
  const spokePool = await (
    await getContractFactory("MockSpokePool", deployerWallet)
  ).deploy(timer.address, weth.address, depositQuoteTimeBuffer);

  return { timer, weth, erc20, spokePool, unwhitelistedErc20 };
}

export interface DepositRoute {
  originToken: string;
  destinationChainId?: number;
  enabled?: boolean;
}
export async function enableRoutes(spokePool: Contract, routes: DepositRoute[]) {
  for (const route of routes) {
    await spokePool.setEnableRoute(
      route.originToken,
      route.destinationChainId ? route.destinationChainId : depositDestinationChainId,
      route.enabled !== undefined ? route.enabled : true
    );
  }
}
