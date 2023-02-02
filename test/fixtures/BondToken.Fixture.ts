import { Contract, getContractFactory, hre } from "../utils";
import { hubPoolFixture } from "./HubPool.Fixture";

export const bondTokenFixture = hre.deployments.createFixture(async ({ ethers }, hubPool?: Contract) => {
  const [deployerWallet] = await ethers.getSigners();

  let collateralWhitelist: Contract | undefined = undefined;

  if (!hubPool) {
    ({ hubPool, collateralWhitelist } = await hubPoolFixture());
  }

  const bondToken = await (await getContractFactory("BondToken", deployerWallet)).deploy(hubPool.address);

  if (collateralWhitelist) {
    await collateralWhitelist.addToWhitelist(bondToken.address);
  }

  return { bondToken };
});
