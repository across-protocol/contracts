import { ethers, getContractFactory } from "../utils/utils";

// This script prints out ABI encoded call data that we can pass to the `relaySpokePoolAdminFunction` functio
// in the HubPool to upgrade a spoke pool to a new implementation and initialize it atomically.
async function main() {
  const [signer] = await ethers.getSigners();

  // Fill in new bridge addresses here:
  const wethBridgeAddress = "0x";
  const erc20BridgeAddress = "0x";
  const spokePool = await getContractFactory("ZkSync_SpokePool", { signer });
  const reinitializeData = spokePool.interface.encodeFunctionData("initialize_v2", [
    wethBridgeAddress,
    erc20BridgeAddress,
  ]);

  // Use newly deployed implementation address grabbed from './deploy/022_upgrade_spokepool.ts' which will validate
  // that the implementation contract correctly upgrades its storage slots and won't accidentally overwrite
  // the proxy's state.
  const newImplementationAddress = "0x";
  const upgradeToAndCall = spokePool.interface.encodeFunctionData("upgradeToAndCall", [
    newImplementationAddress,
    reinitializeData,
  ]);
  console.log(`upgradeToAndCall bytes: `, upgradeToAndCall);

  console.log(`Call relaySpokePoolAdminFunction() with the params [<chainId>, ${upgradeToAndCall}]`);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
