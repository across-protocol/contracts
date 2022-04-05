import * as typeChain from "../typechain";
import * as deploymentExport from "../deployments/deployments.json";

export function getContractArtifact(contractName: string, networkId: number) {
  try {
    return { artifact: [typeChain[contractName]], address: deploymentExport[networkId.toString()][contractName] };
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
