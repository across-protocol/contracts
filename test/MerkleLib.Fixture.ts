import { getContractFactory } from "./utils";
import hre from "hardhat";

export const merkleLibFixture = hre.deployments.createFixture(async ({ deployments }) => {
  await deployments.fixture();
  const [signer] = await hre.ethers.getSigners();
  const merkleLib = await (await getContractFactory("MerkleLib", signer)).deploy();
  const merkleLibTest = await (
    await hre.ethers.getContractFactory("MerkleLibTest", {
      signer,
      libraries: {
        MerkleLib: merkleLib.address,
      },
    })
  ).deploy();
  return { merkleLibTest };
});
