import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments } = hre;
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const hubPool = await deployments.get("HubPool");

  const constructorArguments = [
    hubPool.address,
    L1_ADDRESS_MAP[chainId].blastYieldManager,
    L1_ADDRESS_MAP[chainId].dai,
  ];
  const deployment = await deployments.deploy("Blast_DaiRetriever", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });
  await hre.run("verify:verify", { address: deployment.address, constructorArguments });
};

module.exports = func;
func.tags = ["BlastDaiRetriever", "mainnet"];
