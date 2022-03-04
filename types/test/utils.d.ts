import { expect } from "chai";
import { FakeContract } from "@defi-wonderland/smock";
import hre from "hardhat";
import { ethers } from "hardhat";
import { BigNumber, Signer, Contract, ContractFactory } from "ethers";
import { FactoryOptions } from "hardhat/types";
export interface SignerWithAddress extends Signer {
  address: string;
}
export declare function getContractFactory(
  name: string,
  signerOrFactoryOptions: Signer | FactoryOptions
): Promise<ContractFactory>;
export declare function findArtifactFromPath(contractName: string, artifactsPath: string): any;
export declare function getAllFilesInPath(dirPath: string, arrayOfFiles?: string[]): string[];
export declare const toWei: (num: string | number | BigNumber) => BigNumber;
export declare const toBNWei: (num: string | number | BigNumber) => BigNumber;
export declare const fromWei: (num: string | number | BigNumber) => string;
export declare const toBN: (num: string | number | BigNumber) => BigNumber;
export declare const utf8ToHex: (input: string) => string;
export declare const hexToUtf8: (input: string) => string;
export declare const createRandomBytes32: () => string;
export declare function seedWallet(
  walletToFund: Signer,
  tokens: Contract[],
  weth: Contract | undefined,
  amountToSeedWith: number | BigNumber
): Promise<void>;
export declare function seedContract(
  contract: Contract,
  walletToFund: Signer,
  tokens: Contract[],
  weth: Contract | undefined,
  amountToSeedWith: number | BigNumber
): Promise<void>;
export declare function randomBigNumber(bytes?: number): BigNumber;
export declare function randomAddress(): string;
export declare function getParamType(
  contractName: string,
  functionName: string,
  paramName: string
): Promise<"" | import("@ethersproject/abi").ParamType>;
export declare function createFake(
  contractName: string,
  targetAddress?: string
): Promise<FakeContract<import("ethers").BaseContract>>;
declare function avmL1ToL2Alias(l1Address: string): string;
declare const defaultAbiCoder: import("@ethersproject/abi").AbiCoder,
  keccak256: typeof import("@ethersproject/keccak256").keccak256;
export { avmL1ToL2Alias, expect, Contract, ethers, hre, BigNumber, defaultAbiCoder, keccak256, FakeContract, Signer };
