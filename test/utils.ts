import { getBytecode, getAbi } from "@uma/contracts-node";
import { ethers } from "hardhat";
import { BigNumber, Signer, Contract, ContractFactory } from "ethers";
import { FactoryOptions } from "hardhat/types";

export interface SignerWithAddress extends Signer {
  address: string;
}

function isFactoryOptions(signerOrFactoryOptions: Signer | FactoryOptions): signerOrFactoryOptions is FactoryOptions {
  return "signer" in signerOrFactoryOptions || "libraries" in signerOrFactoryOptions;
}

export async function getContractFactory(
  name: string,
  signerOrFactoryOptions: Signer | FactoryOptions
): Promise<ContractFactory> {
  try {
    return await ethers.getContractFactory(name, signerOrFactoryOptions);
  } catch (error) {
    // If it does not exist then try find the contract in the UMA core package.
    if (isFactoryOptions(signerOrFactoryOptions))
      throw new Error("Cannot pass FactoryOptions to a contract imported from UMA");
    return new ethers.ContractFactory(getAbi(name as any), getBytecode(name as any), signerOrFactoryOptions as Signer);
  }
}

export const toWei = (num: string | number | BigNumber) => ethers.utils.parseEther(num.toString());

export const fromWei = (num: string | number | BigNumber) => ethers.utils.formatUnits(num.toString());

export const toBN = (num: string | number | BigNumber) => {
  // If the string version of the num contains a `.` then it is a number which needs to be parsed to a string int.
  if (num.toString().includes(".")) return BigNumber.from(parseInt(num as any));
  return BigNumber.from(num.toString());
};

export const utf8ToHex = (input: string) => ethers.utils.formatBytes32String(input);

export const hexToUtf8 = (input: string) => ethers.utils.toUtf8String(input);

export const createRandomBytes32 = () => ethers.utils.hexlify(ethers.utils.randomBytes(32));

export async function seedWallet(
  walletToFund: Signer,
  tokens: Contract[],
  weth: Contract | undefined,
  amountToSeedWith: number | BigNumber
) {
  for (const token of tokens) await token.mint(await walletToFund.getAddress(), amountToSeedWith);

  if (weth) await weth.connect(walletToFund).deposit({ value: amountToSeedWith });
}

export function randomBigNumber() {
  return ethers.BigNumber.from(ethers.utils.randomBytes(31));
}

export function randomAddress() {
  return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}
