import { ethers } from "ethers";
import HubPoolArtifact from "../../../out/HubPool.sol/HubPool.json";

export function getHubPoolContract(address: string, signerOrProvider: ethers.Signer | ethers.providers.Provider) {
  return new ethers.Contract(address, HubPoolArtifact.abi, signerOrProvider);
}

export const requireEnv = (name: string): string => {
  if (!process.env[name]) throw new Error(`Environment variable ${name} is not set`);
  return process.env[name];
};
