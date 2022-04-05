import * as typeChain from "../typechain";
import * as deploymentExport from "../deployments/deployments.json";

function getDeploymentAddress(contractName: string, networkId: number) {
  try {
    return deploymentExport[networkId.toString()][contractName];
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
export function getContractArtifact(contractName: string, networkId: number) {
  try {
    return { artifact: [typeChain[contractName]], address: getDeploymentAddress(contractName, networkId) };
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
