import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const hubPool = await deployments.get("HubPool");
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  const constructorArguments = [hubPool.address, L1_ADDRESS_MAP[chainId].blastYieldManager];
  const deployment = await deploy("Blast_RescueAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });
  await run("verify:verify", { address: deployment.address, constructorArguments });
};

module.exports = func;
func.tags = ["BlastRescueAdapter", "mainnet"];
