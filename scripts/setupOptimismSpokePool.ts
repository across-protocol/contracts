// @notice Logs ABI-encoded function data that can be relayed from HubPool to OptimismSpokePool to set it up.

import { getContractFactory, ethers } from "../utils/utils";
import { constants } from "@across-protocol/sdk-v2";
const { CHAIN_IDs } = constants;

const customOptimismTokenBridges: Record<string, string> = {
  // DAI
  "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1": "0x467194771dAe2967Aef3ECbEDD3Bf9a310C76C65",
};

async function main() {
  const [signer] = await ethers.getSigners();

  const spokePool = await getContractFactory("Ovm_SpokePool", { signer });
  const hubPool = await getContractFactory("HubPool", { signer });

  // We need to whitelist all L2 --> L1 token mappings
  // We'll use this to store all the call data we need to pass to HubPool#multicall.
  const callData: string[] = [];

  for (const l2Token of Object.keys(customOptimismTokenBridges)) {
    // Setup Optimism: We need to call setTokenBridge on Optimism SpokePool so that SpokePool
    // is aware of L2 custom bridge mappings.
    const bridge = customOptimismTokenBridges[l2Token];
    const _callData = spokePool.interface.encodeFunctionData("setTokenBridge", [l2Token, bridge]);
    console.log(`Setting token bridge for ${l2Token} on Optimism SpokePool: ${_callData}`);
    const relayRootCallData = hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [
      CHAIN_IDs.OPTIMISM,
      _callData,
    ]);
    callData.push(relayRootCallData);
  }

  const multicallData = hubPool.interface.encodeFunctionData("multicall", [callData]);
  console.log("Data to pass to HubPool#multicall()", multicallData);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
