import { TokenRolesEnum, interfaceName } from "@uma/common";
import { getContractFactory, SignerWithAddress, utf8ToHex, toWei, toBN } from "./utils";
import { bondAmount, refundProposalLiveness, identifier } from "./constants";
import { Contract } from "ethers";

export async function deployHubPoolTestHelperContracts(deployer: SignerWithAddress, finder: Contract, timer: Contract) {
  // Create 3 tokens: WETH for wrapping unwrapping and 2 ERC20s with different decimals.
  const weth = await (await getContractFactory("WETH9", deployer)).deploy();
  const usdc = await (await getContractFactory("ExpandedERC20", deployer)).deploy("USD Coin", "USDC", 6);
  await usdc.addMember(TokenRolesEnum.MINTER, deployer.address);
  const dai = await (await getContractFactory("ExpandedERC20", deployer)).deploy("DAI Stablecoin", "DAI", 18);
  await dai.addMember(TokenRolesEnum.MINTER, deployer.address);

  // Set the above currencies as approved in the UMA collateralWhitelist.
  const collateralWhitelist = await (
    await getContractFactory("AddressWhitelist", deployer)
  ).attach(await finder.getImplementationAddress(utf8ToHex(interfaceName.CollateralWhitelist)));
  await collateralWhitelist.addToWhitelist(weth.address);
  await collateralWhitelist.addToWhitelist(usdc.address);
  await collateralWhitelist.addToWhitelist(dai.address);

  // Set the finalFee for all the new tokens.
  const store = await (
    await getContractFactory("Store", deployer)
  ).attach(await finder.getImplementationAddress(utf8ToHex(interfaceName.Store)));
  await store.setFinalFee(weth.address, { rawValue: toWei("1") });
  await store.setFinalFee(usdc.address, { rawValue: toBN("1000").mul(1e6) });
  await store.setFinalFee(dai.address, { rawValue: toWei("1000") });

  // Deploy the hubPool.
  const hubPool = await (
    await getContractFactory("HubPool", deployer)
  ).deploy(bondAmount, refundProposalLiveness, finder.address, identifier, weth.address, weth.address, timer.address);

  return { weth, usdc, dai, hubPool };
}

export async function enableTokensForLiquidityProvision(owner: any, hubPool: Contract, tokens: Contract[]) {
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
