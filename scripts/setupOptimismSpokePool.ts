// @notice Logs ABI-encoded function data that can be relayed from HubPool to OptimismSpokePool to set it up.

import { ethers } from "ethers";
import { CHAIN_IDs } from "../utils/constants";
import { findArtifactFromPath } from "../utils/utils";

const ARTIFACTS_PATH = "out";

const customOptimismTokenBridges: Record<string, string> = {
  // DAI
  "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1": "0x467194771dAe2967Aef3ECbEDD3Bf9a310C76C65",
};

async function main() {
  const spokePoolArtifact = findArtifactFromPath("Ovm_SpokePool", ARTIFACTS_PATH);
  const hubPoolArtifact = findArtifactFromPath("HubPool", ARTIFACTS_PATH);

  const spokePoolInterface = new ethers.utils.Interface(spokePoolArtifact.abi);
  const hubPoolInterface = new ethers.utils.Interface(hubPoolArtifact.abi);

  // We need to whitelist all L2 --> L1 token mappings
  // We'll use this to store all the call data we need to pass to HubPool#multicall.
  const callData: string[] = [];

  for (const l2Token of Object.keys(customOptimismTokenBridges)) {
    // Setup Optimism: We need to call setTokenBridge on Optimism SpokePool so that SpokePool
    // is aware of L2 custom bridge mappings.
    const bridge = customOptimismTokenBridges[l2Token];
    const _callData = spokePoolInterface.encodeFunctionData("setTokenBridge", [l2Token, bridge]);
    console.log(`Setting token bridge for ${l2Token} on Optimism SpokePool: ${_callData}`);
    const relayRootCallData = hubPoolInterface.encodeFunctionData("relaySpokePoolAdminFunction", [
      CHAIN_IDs.OPTIMISM,
      _callData,
    ]);
    callData.push(relayRootCallData);
  }

  const multicallData = hubPoolInterface.encodeFunctionData("multicall", [callData]);
  console.log("Data to pass to HubPool#multicall()", multicallData);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
