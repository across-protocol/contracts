import { ethers, getContractFactory } from "../utils/utils";

async function main() {
  if (!process.env.NEW_SPOKE_POOL) {
    console.log("Usage: NEW_SPOKE_POOL=<NEW_SPOKE_POOL_ADDRESS> yarn hardhat run scripts/upgradeTo.ts");
    return;
  }
  // @dev This should throw if the address is invalid.
  const newSpokePoolAddress = ethers.utils.getAddress(process.env.NEW_SPOKE_POOL);
  const [signer] = await ethers.getSigners();

  // @dev Any spoke pool's interface can be used here since they all should have the same upgradeTo function signature.
  const spokePool = await getContractFactory("Arbitrum_SpokePool", { signer });

  const upgradeTo = spokePool.interface.encodeFunctionData("upgradeTo", [newSpokePoolAddress]);
  console.log(`upgradeTo bytes: `, upgradeTo);

  console.log(
    `Call relaySpokePoolAdminFunction() with the params [<chainId>, ${upgradeTo}] on the hub pool from the owner's account.`
  );
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
