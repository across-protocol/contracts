import { Contract, getContractFactory, hre } from "../utils";
import { hubPoolFixture } from "./HubPool.Fixture";

export const bondTokenFixture = hre.deployments.createFixture(async ({ ethers }) => {
  const [deployerWallet] = await ethers.getSigners();

  let hubPool: Contract;
  let collateralWhitelist: Contract;
  ({ hubPool, collateralWhitelist } = await hubPoolFixture());
  const bondToken = await (await getContractFactory("BondToken", deployerWallet)).deploy(hubPool.address);
  await collateralWhitelist.addToWhitelist(bondToken.address);

  return { bondToken, hubPool };
});
