import * as deployments_ from "../deployments/deployments.json";
interface DeploymentExport {
  [chainId: string]: { [contractName: string]: { address: string; blockNumber: number } };
}
const deployments: DeploymentExport = deployments_ as any;

// Returns the deployed address of any contract on any network.
export function getDeployedAddress(contractName: string, networkId: number): string {
  try {
    return deployments[networkId.toString()][contractName].address;
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}

// Returns the deployment block number of any contract on any network.
export function getDeployedBlockNumber(contractName: string, networkId: number): number {
  try {
    return deployments[networkId.toString()][contractName].blockNumber;
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}

// Returns the chainId and contract name for a given contract address.
export function getContractInfoFromAddress(contractAddress: string): { chainId: Number; contractName: string } {
  try {
    let returnValue = { chainId: 0, contractName: "" };

    Object.keys(deployments).forEach((_chainId) =>
      Object.keys(deployments[_chainId]).forEach((_contractName) => {
        if (deployments[_chainId][_contractName].address == contractAddress) {
          returnValue = { chainId: Number(_chainId), contractName: _contractName };
          return;
        }
      })
    );
    return returnValue;
  } catch (_) {
    throw new Error(`Contract ${contractAddress} was not found in deployments.`);
  }
}
