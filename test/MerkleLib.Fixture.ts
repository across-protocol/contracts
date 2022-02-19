import { getContractFactory } from "./utils";
import hre from "hardhat";

export const merkleLibFixture = hre.deployments.createFixture(async ({ deployments }) => {
  const [signer] = await hre.ethers.getSigners();
  const merkleLibTest = await (await getContractFactory("MerkleLibTest", { signer })).deploy();
  return { merkleLibTest };
});
