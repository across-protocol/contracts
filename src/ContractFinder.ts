import * as typeChain from "../typechain";
import * as deploymentExport from "../deployments/deployments.json";

function getDeploymentAddress(contractName: string, networkId: number) {
  try {
    return { artifact: [typeChain[contractName]], address: getDeploymentAddress(contractName, networkId) };
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
  return deploymentExport[networkId.toString()][contractName];
}
export function getContractArtifact(contractName: string, networkId: number) {
  try {
    return { artifact: [typeChain[contractName]], address: getDeploymentAddress(contractName, networkId) };
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
