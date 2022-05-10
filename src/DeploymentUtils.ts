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

export function getContractInfoFromAddress(searchedForAddress: string): { chainId: Number; contractName: string } {
  try {
    let chainId = 0;
    let contractName = "";
    const allChainDeployments = deployments as any;

    Object.keys(allChainDeployments).forEach((_chainId) =>
      Object.keys(allChainDeployments[_chainId]).forEach((_contractName) => {
        if (allChainDeployments[_chainId][_contractName].address == searchedForAddress) {
          chainId = Number(_chainId);
          contractName = _contractName;
          return;
        }
      })
    );
    return { chainId, contractName };
  } catch (_) {
    throw new Error(`Contract ${searchedForAddress} was not found in deployments.`);
  }
}
