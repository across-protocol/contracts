import * as deployments from "../deployments/deployments.json";

export function getDeployedAddress(contractName: string, networkId: number): string {
  try {
    return (deployments as any)[networkId.toString()][contractName];
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
