import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "hardhat-deploy";
import { deployNewProxy } from "../utils/utils.hre";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await deployNewProxy("AdapterStore", [], []);
};

module.exports = func;
func.tags = ["AdapterStore", "mainnet"];
