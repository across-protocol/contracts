import { TokenRolesEnum, interfaceName } from "@uma/common";
import { getContractFactory, utf8ToHex, toBN, fromWei } from "./utils";
import { bondAmount, refundProposalLiveness, finalFee, identifier } from "./constants";
import { Contract, Signer } from "ethers";
import hre from "hardhat";

import { umaEcosystemFixture } from "./umaEcosystem.Fixture";

export const hubPoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  const [signer] = await ethers.getSigners();

  // This fixture is dependent on the UMA ecosystem fixture. Run it first and grab the output. This is used in the
  // deployments that follows. The output is spread when returning contract instances from this fixture.
  const parentFixtureOutput = await umaEcosystemFixture();

  // Create 3 tokens: WETH for wrapping unwrapping and 2 ERC20s with different decimals.
  const weth = await (await getContractFactory("WETH9", signer)).deploy();
  const usdc = await (await getContractFactory("ExpandedERC20", signer)).deploy("USD Coin", "USDC", 6);
  await usdc.addMember(TokenRolesEnum.MINTER, signer.address);
  const dai = await (await getContractFactory("ExpandedERC20", signer)).deploy("DAI Stablecoin", "DAI", 18);
  await dai.addMember(TokenRolesEnum.MINTER, signer.address);

  // Set the above currencies as approved in the UMA collateralWhitelist.
  await parentFixtureOutput.collateralWhitelist.addToWhitelist(weth.address);
  await parentFixtureOutput.collateralWhitelist.addToWhitelist(usdc.address);
  await parentFixtureOutput.collateralWhitelist.addToWhitelist(dai.address);

  // Set the finalFee for all the new tokens.
  await parentFixtureOutput.store.setFinalFee(weth.address, { rawValue: finalFee });
  await parentFixtureOutput.store.setFinalFee(usdc.address, { rawValue: toBN(fromWei(finalFee)).mul(1e6) });
  await parentFixtureOutput.store.setFinalFee(dai.address, { rawValue: finalFee });

  // Deploy the hubPool
  const merkleLib = await (await getContractFactory("MerkleLib", signer)).deploy();
  const hubPool = await (
    await getContractFactory("HubPool", { signer: signer, libraries: { MerkleLib: merkleLib.address } })
  ).deploy(
    bondAmount,
    refundProposalLiveness,
    parentFixtureOutput.finder.address,
    identifier,
    weth.address,
    weth.address,
    parentFixtureOutput.timer.address
  );

  return { weth, usdc, dai, hubPool, ...parentFixtureOutput };
});

export async function enableTokensForLiquidityProvision(owner: Signer, hubPool: Contract, tokens: Contract[]) {
  const lpTokens = [];
  for (const token of tokens) {
    await hubPool.enableL1TokenForLiquidityProvision(token.address);
    lpTokens.push(
      await (
        await getContractFactory("ExpandedERC20", owner)
      ).attach((await hubPool.callStatic.lpTokens(token.address)).lpToken)
    );
  }
  return lpTokens;
}
