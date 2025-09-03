import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

task("upgrade-spokepool", "Generate calldata to upgrade a SpokePool deployment")
  .addParam("implementation", "New SpokePool implementation address")
  .addOptionalParam("upgradeOnly", "Upgrade only, do not pause/unpause deposits")
  .setAction(async function (args, hre: HardhatRuntimeEnvironment) {
    const { implementation, upgradeOnly } = args;
    if (!implementation) {
      console.log("Usage: yarn hardhat upgrade-spokepool --implementation <implementation>");
      return;
    }

    const { ethers } = hre;

    if (ethers.utils.getAddress(implementation) !== implementation) {
      throw new Error(`Implementation address must be checksummed (${implementation})`);
    }

    // @dev Any spoke pool's interface can be used here since they all should have the same upgradeTo function signature.
    const abi = [
      {
        inputs: [
          {
            internalType: "address",
            name: "newImplementation",
            type: "address",
          },
        ],
        name: "upgradeTo",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [
          {
            internalType: "address",
            name: "newImplementation",
            type: "address",
          },
          { internalType: "bytes", name: "data", type: "bytes" },
        ],
        name: "upgradeToAndCall",
        outputs: [],
        stateMutability: "payable",
        type: "function",
      },
      {
        inputs: [{ internalType: "bytes[]", name: "data", type: "bytes[]" }],
        name: "multicall",
        outputs: [{ internalType: "bytes[]", name: "results", type: "bytes[]" }],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [{ internalType: "bool", name: "pause", type: "bool" }],
        name: "pauseDeposits",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },
    ];
    const spokePool = new ethers.Contract(implementation, abi);

    let calldata = "";
    if (upgradeOnly) {
      calldata = spokePool.interface.encodeFunctionData("upgradeTo", [implementation]);
      console.log(`upgradeTo bytes: `, calldata);
    } else {
      /**
       * We perform this seemingly unnecessary pause/unpause sequence because we want to ensure that the
       * upgrade is successful and the new implementation is functioning correctly.
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
      console.log(`upgradeToAndCall bytes: `, calldata);
    }

    console.log(
      `Call relaySpokePoolAdminFunction() with the params [<chainId>, ${calldata}] on the hub pool from the owner's account.`
    );
  });
