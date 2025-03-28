import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployNewProxy } from "../utils/utils.hre";
import { TOKEN_SYMBOLS_MAP } from "../utils";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const chainId = parseInt(await hre.getChainId());
  const admin = "0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D";
  const initArgs = [
    admin, // No bridge is used; permit dev wallet to call directly.
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    // Set dev wallet as cross-domain admin because there is no available bridge.
    admin,
    admin,
  ];
  const constructorArgs = [
    TOKEN_SYMBOLS_MAP["TATARA-WETH"].addresses[chainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
  ];

  await deployNewProxy("Tatara_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["TataraSpokePool", "Tatara"];
