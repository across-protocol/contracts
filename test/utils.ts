import { getBytecode, getAbi } from "@uma/contracts-node";

import { ethers } from "hardhat";

export async function getContract(name: string): Promise<{ abi: any[]; bytecode: string }> {
    try {
      // Try fetch from the local ethers factory from HRE. If this exists then the contract is in this package.
      const ethersFactory = await ethers.getContractFactory(name);
      return { bytecode: ethersFactory.bytecode, abi: ethersFactory.interface as any };
    } catch (error) { }
    // If it does not exist then try find the contract in the UMA core package.
  return { bytecode: getBytecode(name as any), abi: getAbi(name as any) };
}
