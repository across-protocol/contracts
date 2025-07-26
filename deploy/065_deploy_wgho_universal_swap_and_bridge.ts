import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { TOKEN_SYMBOLS_MAP } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Wgho_UniversalSwapAndBridge", {
    contract: "UniversalSwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    deterministicDeployment: "0x123456789abc", // Salt for the create2 call.
    args: [
      getDeployedAddress("SpokePool", chainId),
      TOKEN_SYMBOLS_MAP.WGHO.addresses[chainId],
      // Allows function selectors in WGHO:
      // - transferFrom
      // - withdrawTo
      // - depositFor
      // See https://etherscan.io/address/0x1ff1dC3cB9eeDbC6Eb2d99C03b30A05cA625fB5a#writeProxyContract
      ["0x205c2878", "0x23b872dd", "0x2f4f21e2"],
    ],
  });
};
module.exports = func;
func.tags = ["Wgho_UniversalSwapAndBridge", "UniversalSwapAndBridge", "wgho"];
