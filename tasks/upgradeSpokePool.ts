import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

task("upgrade-spokepool", "Generate calldata to upgrade a SpokePool deployment")
  .addParam("implementation", "New SpokePool implementation address")
  .setAction(async function (args, hre: HardhatRuntimeEnvironment) {
    const { implementation } = args;
    if (!implementation) {
      console.log("Usage: yarn hardhat upgrade-spokepool --implementation <implementation>");
      return;
    }

    const { ethers } = hre;

    if (ethers.utils.getAddress(implementation) !== implementation) {
      throw new Error(`Implementation address must be checksummed (${implementation})`);
    }

    // @dev Any spoke pool's interface can be used here since they all should have the same upgradeTo function signature.
    const abi = ["function upgradeTo(address newImplementation) external"];
    const spokePool = new ethers.Contract(implementation, abi);

    const upgradeTo = spokePool.interface.encodeFunctionData("upgradeTo", [implementation]);
    console.log(`upgradeTo bytes: `, upgradeTo);

    console.log(
      `Call relaySpokePoolAdminFunction() with the params [<chainId>, ${upgradeTo}] on the hub pool from the owner's account.`
    );
  });
