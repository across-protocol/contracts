import * as deployments from "../deployments/deployments.json";

// Returns the deployed address of any contract on any network.
export function getDeployedAddress(contractName: string, networkId: number): string {
  try {
    return (deployments as any)[networkId.toString()][contractName].address;
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}

// Returns the deployment block number of any contract on any network.
export function getDeployedBlockNumber(contractName: string, networkId: number): string {
  try {
    return (deployments as any)[networkId.toString()][contractName].blockNumber;
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}
