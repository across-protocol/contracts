import { getBytecode, getAbi } from "@uma/contracts-node";

import { ethers } from "hardhat";

export async function getContractFactory(name: string, signer: any) {
  try {
    // Try fetch from the local ethers factory from HRE. If this exists then the contract is in this package.
    return await ethers.getContractFactory(name);
  } catch (error) {}
  // If it does not exist then try find the contract in the UMA core package.
  return new ethers.ContractFactory(getAbi(name as any), getBytecode(name as any), signer);
}
