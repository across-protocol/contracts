import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  // @note if deploying this contract on a chain like Linea that only supports up to
  // solc 0.8.19, the hardhat.config solc version needs to be overridden and this
  // contract needs to be recompiled.
  await deploy("Multicallhandler", {
    contract: "MulticallHandler",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
    deterministicDeployment: "0x12345678", // Salt for the create2 call. This will deploy this contract
    // at the same address on all chains except ZkSync and Linea which are not EVM equivalent.
  });
};
module.exports = func;
func.tags = ["Multicallhandler"];
