// @notice Logs ABI-encoded function data that can be relayed from HubPool to ArbitrumSpokePool to set it up.

import { getContractFactory, ethers, hre } from "../utils/utils";
import * as consts from "../test/constants";

async function main() {
  const [signer] = await ethers.getSigners();

  // We need to whitelist L2 --> L1 token mappings
  const spokePool = await getContractFactory("Arbitrum_SpokePool", { signer });
  const whitelistWeth = spokePool.interface.encodeFunctionData("whitelistToken", [
    "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681", // L2 WETH
    "0xc778417e063141139fce010982780140aa0cd5ab", // L1 WETH
  ]);
  console.log(`(WETH) whitelistToken: `, whitelistWeth);

  // USDC is also not verified on the rinkeby explorer so we should approve it to be spent by the spoke pool.
  const ERC20 = await getContractFactory("ExpandedERC20", { signer });
  const usdc = await ERC20.attach("0x4dbcdf9b62e891a7cec5a2568c3f4faf9e8abe2b");
  const deployedHubPool = await hre.deployments.get("HubPool");
  const approval = await usdc.approve(deployedHubPool.address, consts.maxUint256);
  console.log(`Approved USDC to be spent by HubPool @ ${deployedHubPool.address}: `, approval.hash);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
