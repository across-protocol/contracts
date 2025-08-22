import * as deployments_ from "../deployments/deployments.json";

/** Mapping: chainId -> contractName -> { address, blockNumber }. */
export type Deployments = Record<string, Record<string, { address: string; blockNumber: number }>>;

export const DEPLOYMENTS: Readonly<Deployments> = deployments_ as Deployments;

/**
 * Returns the deployed address of any contract on any network.
 */
export function getDeployedAddress(
  contractName: string,
  networkId: number | string,
  throwOnError = true
): string | undefined {
  const address = DEPLOYMENTS[networkId.toString()]?.[contractName]?.address;
  if (!address && throwOnError) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }

  return address;
}

/**
 * Returns all active deployments for a given contract name across all chains.
 * Each result contains chainId, address, and blockNumber.
 */
export function getAllDeployedAddresses(
  contractName: string
): Array<{ chainId: number; address: string; blockNumber: number }> {
  const results: Array<{ chainId: number; address: string; blockNumber: number }> = [];
  Object.keys(DEPLOYMENTS).forEach((_chainId) => {
    const info = DEPLOYMENTS[_chainId]?.[contractName];
    if (info?.address) {
      results.push({ chainId: Number(_chainId), address: info.address, blockNumber: info.blockNumber });
    }
  });
  return results;
}

/**
 * Returns the deployment block number of any contract on any network.
 */
export function getDeployedBlockNumber(contractName: string, networkId: number): number {
  try {
    return DEPLOYMENTS[networkId.toString()][contractName].blockNumber;
  } catch (_) {
    throw new Error(`Contract ${contractName} not found on ${networkId} in deployments.json`);
  }
}

/**
 * Returns the chainId and contract name for a given contract address.
 */
export function getContractInfoFromAddress(contractAddress: string): { chainId: Number; contractName: string } {
  const returnValue: { chainId: number; contractName: string }[] = [];

  Object.keys(DEPLOYMENTS).forEach((_chainId) =>
    Object.keys(DEPLOYMENTS[_chainId]).forEach((_contractName) => {
      if (DEPLOYMENTS[_chainId][_contractName].address === contractAddress)
        returnValue.push({ chainId: Number(_chainId), contractName: _contractName });
    })
  );
  if (returnValue.length === 0) throw new Error(`Contract ${contractAddress} not found in deployments.json`);
  if (returnValue.length > 1) throw new Error(`Multiple deployments found for ${contractAddress}`);
  return returnValue[0];
}
