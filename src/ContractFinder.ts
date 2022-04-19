import * as deployments from "../deployments/deployments.json";

// Returns the deployed address of any contract on any network. Uses the pruned network file in the deployments directory.
// Note that we dont export the contract ABI or bytecode. Implementors are expected to use the typechain artifacts.
export function getDeployedAddress(contractName: string, networkId: number): string {
  try {
    return (deployments as any)[networkId.toString()][contractName];
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}
