import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;
  const hubPool = await deployments.get("HubPool");
  const chainId = parseInt(await getChainId());

  const constructorArguments = [
    hubPool.address,
    L1_ADDRESS_MAP[chainId].blastYieldManager,
    L1_ADDRESS_MAP[chainId].dai,
  ];
  const deployment = await deploy("Blast_DaiRetriever", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });
  await run("verify:verify", { address: deployment.address, constructorArguments });
};

module.exports = func;
func.tags = ["BlastDaiRetriever", "mainnet"];
