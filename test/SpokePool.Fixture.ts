import { TokenRolesEnum } from "@uma/common";
import { Contract } from "ethers";
import { getContractFactory } from "./utils";
import { depositDestinationChainId } from "./constants"

export async function deploySpokePoolTestHelperContracts(deployerWallet: any) {
  // Useful contracts.
  const timer = await (await getContractFactory("Timer", deployerWallet)).deploy();

  // Create tokens:
  const weth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const erc20 = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("USD Coin", "USDC", 18);
  await erc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);
  const destWeth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const destErc20 = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("Destination USD Coin", "destUSDC", 18);
  await destErc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the pool
  const spokePool = await (await getContractFactory("MockSpokePool", deployerWallet)).deploy(timer.address);

  return { timer, weth, erc20, destWeth, destErc20, spokePool };
}

export interface DepositRoute {
    originToken: string;
    destinationToken: string;
    spokePool?: string;
    isWethToken: boolean;
    destinationChainId?: number;
}
export async function whitelistRoutes(spokePool: Contract, routes: DepositRoute[]) {
  for (const route of routes) {
      await spokePool.whitelistRoute(
          route.originToken,
          route.destinationToken,
          route.spokePool ? route.spokePool : spokePool.address,
          route.isWethToken,
          route.destinationChainId ? route.destinationChainId : depositDestinationChainId
      );
  };
}

