import { TokenRolesEnum } from "@uma/common";
import { getContractFactory } from "./utils";
import { bondAmount, refundProposalLiveness } from "./constants";
import { Contract, Signer } from "ethers";
import hre from "hardhat";

export const hubPoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  const [deployerWallet] = await ethers.getSigners();

  // Useful contracts.
  const timer = await (await getContractFactory("Timer", deployerWallet)).deploy();

  // Create 3 tokens: WETH for wrapping unwrapping and 2 ERC20s with different decimals.
  const weth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const usdc = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("USD Coin", "USDC", 6);
  await usdc.addMember(TokenRolesEnum.MINTER, deployerWallet.address);
  const dai = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("DAI Stablecoin", "DAI", 18);
  await dai.addMember(TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the hubPool
  const merkleLib = await (await getContractFactory("MerkleLib", deployerWallet)).deploy();
  const hubPool = await (
    await getContractFactory("HubPool", { signer: deployerWallet, libraries: { MerkleLib: merkleLib.address } })
  ).deploy(bondAmount, refundProposalLiveness, weth.address, weth.address, timer.address);

  return { timer, weth, usdc, dai, hubPool };
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
