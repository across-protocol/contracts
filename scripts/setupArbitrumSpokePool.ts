// @notice Logs ABI-encoded function data that can be relayed from HubPool to ArbitrumSpokePool to set it up.

import { getContractFactory, ethers } from "../test/utils";

async function main() {
  const [signer] = await ethers.getSigners();

  // We need to whitelist L2 --> L1 token mappings
  const spokePool = await getContractFactory("Arbitrum_SpokePool", { signer });
  const whitelistWeth = spokePool.interface.encodeFunctionData("whitelistToken", [
    "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681", // L2 WETH
    "0xc778417e063141139fce010982780140aa0cd5ab", // L1 WETH
  ]);
  console.log(`(WETH) whitelistToken: `, whitelistWeth);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
