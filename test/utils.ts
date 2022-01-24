import { getBytecode, getAbi } from "@uma/contracts-node";

import { ethers } from "hardhat";

export async function getContract(name: string): Promise<{ abi: any[]; bytecode: string }> {
  try {
    const ethersFactory = await ethers.getContractFactory(name);
    return { bytecode: ethersFactory.bytecode, abi: ethersFactory.interface as any };
  } catch (error) {}
  return { bytecode: getBytecode(name as any), abi: getAbi(name as any) };
}
