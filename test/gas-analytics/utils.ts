import { SignerWithAddress, getContractFactory } from "../utils";
import { TokenRolesEnum } from "@uma/common";

export async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(TokenRolesEnum.MINTER, signer.address);
  return erc20;
}
