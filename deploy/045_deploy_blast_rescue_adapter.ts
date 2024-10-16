import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments } = hre;
  const { deployer } = await hre.getNamedAccounts();
  const hubPool = await deployments.get("HubPool");
  const chainId = parseInt(await hre.getChainId());

  const constructorArguments = [hubPool.address, L1_ADDRESS_MAP[chainId].blastYieldManager];
  const deployment = await deployments.deploy("Blast_RescueAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });
  await hre.run("verify:verify", { address: deployment.address, constructorArguments });
};

module.exports = func;
func.tags = ["BlastRescueAdapter", "mainnet"];
