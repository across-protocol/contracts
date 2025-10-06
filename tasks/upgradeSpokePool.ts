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

    const artifact = await hre.artifacts.readArtifact("SpokePool");

    // @dev Any spoke pool's interface can be used here since they all should have the same upgradeTo function signature.
    const abi = artifact.abi;
    const spokePool = new ethers.Contract(implementation, abi);

    let calldata = "";

    /**
     * We perform this seemingly unnecessary pause/unpause sequence because we want to ensure that the
     * upgrade is successful and the new implementation gets forwarded calls by the proxy contract as expected
     *
     * Since the upgrade and call happens atomically, the upgrade will revert if the new implementation
     * is not functioning correctly.
     */
    const data = spokePool.interface.encodeFunctionData("multicall", [
      [
        spokePool.interface.encodeFunctionData("pauseDeposits", [true]),
        spokePool.interface.encodeFunctionData("pauseDeposits", [false]),
      ],
    ]);

    calldata = spokePool.interface.encodeFunctionData("upgradeToAndCall", [implementation, data]);
    console.log(
      `Call relaySpokePoolAdminFunction() with the params [<chainId>, ${calldata}] on the hub pool from the owner's account.`
    );
  });
