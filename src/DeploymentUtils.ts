import * as deployments_ from "../deployments/deployments.json";

interface DeploymentExport {
  [chainId: string]: { [contractName: string]: { address: string; blockNumber: number } };
}
const deployments: DeploymentExport = deployments_ as any;

// Returns the deployed address of any contract on any network.
export function getDeployedAddress(contractName: string, networkId: number, throwOnError = true): string | undefined {
  const address = deployments[networkId.toString()]?.[contractName]?.address;
  if (!address && throwOnError) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }

  return address;
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
  const returnValue: { chainId: number; contractName: string }[] = [];

  Object.keys(deployments).forEach((_chainId) =>
    Object.keys(deployments[_chainId]).forEach((_contractName) => {
      if (deployments[_chainId][_contractName].address === contractAddress)
        returnValue.push({ chainId: Number(_chainId), contractName: _contractName });
    })
  );
  if (returnValue.length === 0) throw new Error(`Contract ${contractAddress} not found in deployments.json`);
  if (returnValue.length > 1) throw new Error(`Multiple deployments found for ${contractAddress}`);
  return returnValue[0];
}
