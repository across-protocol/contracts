import * as typeChain from "../typechain";
import * as deployments from "../deployments/deployments.json";

export function getContractArtifact(contractName: string, networkId: number) {
  try {
    return {
      artifact: [typeChain[`${contractName}__factory`]],
      address: deployments[networkId.toString()][contractName],
    };
  } catch (error) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in export.json`);
  }
}
