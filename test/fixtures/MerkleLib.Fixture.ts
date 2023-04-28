import { Contract, getContractFactory, hre } from "../../utils/utils";

export const merkleLibFixture: () => Promise<{ merkleLibTest: Contract }> = hre.deployments.createFixture(async () => {
  const [signer] = await hre.ethers.getSigners();
  const merkleLibTest = await (await getContractFactory("MerkleLibTest", { signer })).deploy();
  return { merkleLibTest };
});
