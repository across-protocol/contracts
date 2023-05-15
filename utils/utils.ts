import fs from "fs";
import path from "path";
import { expect } from "chai";
import * as chai from "chai";
import { getBytecode, getAbi } from "@uma/contracts-node";
import * as optimismContracts from "@eth-optimism/contracts";
import { smock, FakeContract } from "@defi-wonderland/smock";
import { FactoryOptions } from "hardhat/types";
import hre from "hardhat";
import { ethers } from "hardhat";
import { BigNumber, Signer, Contract, ContractFactory } from "ethers";
export { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

chai.use(smock.matchers);

function isFactoryOptions(signerOrFactoryOptions: Signer | FactoryOptions): signerOrFactoryOptions is FactoryOptions {
  return "signer" in signerOrFactoryOptions || "libraries" in signerOrFactoryOptions;
}

export async function getContractFactory(
  name: string,
  signerOrFactoryOptions: Signer | FactoryOptions
): Promise<ContractFactory> {
  try {
    // First, try get the artifact from this repo.
    return await ethers.getContractFactory(name, signerOrFactoryOptions);
  } catch (_) {
    try {
      // If it does not exist then try find the contract in the UMA core package.
      if (isFactoryOptions(signerOrFactoryOptions))
        throw new Error("Cannot pass FactoryOptions to a contract imported from UMA");
      return new ContractFactory(getAbi(name as any), getBytecode(name as any), signerOrFactoryOptions as Signer);
    } catch (_) {
      // If that also fails, try fetching it from Optimism package.
      try {
        return await optimismContracts.getContractFactory(name, signerOrFactoryOptions as Signer);
      } catch (_) {
        // If that also fails, then try getting it from the Arbitrum package.
        try {
          const arbitrumArtifact = getArbitrumArtifact(name);
          return new ContractFactory(arbitrumArtifact.abi, arbitrumArtifact.bytecode, signerOrFactoryOptions as Signer);
        } catch (_) {
          // Finally, try importing the package from the local path. This would be the case when running these utils
          // from node modules which breaks using the hardhat getContractFactory function.
          try {
            const localArtifact = getLocalArtifact(name);
            return new ContractFactory(localArtifact.abi, localArtifact.bytecode, signerOrFactoryOptions as Signer);
          } catch (_) {
            throw new Error(`Could not find the artifact for ${name}!`);
          }
        }
      }
    }
  }
}

export async function deployNewProxy(name: string, args: (number | string)[]): Promise<void> {
  const { run, upgrades } = hre;

  const proxy = await upgrades.deployProxy(await getContractFactory(name, {}), args, { kind: "uups" });
  const instance = await proxy.deployed();
  console.log(`New ${name} proxy deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`${name} implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", {
    address: instance.address,
  });
}

// Arbitrum does not export any of their artifacts nicely, so we have to do this manually. The methods that follow can
// be re-used if we end up requiring to import contract artifacts from other projects that dont export cleanly.
function getArbitrumArtifact(contractName: string) {
  try {
    // First, try find the contract from their main package.
    const artifactsPath = `${findPathToRootOfPackage("arb-bridge-eth")}build/contracts/contracts`;
    return findArtifactFromPath(contractName, artifactsPath);
  } catch (error) {
    // If that fails then try from the peripheral package.
    const artifactsPath = `${findPathToRootOfPackage("arb-bridge-peripherals")}build/contracts/contracts`;
    return findArtifactFromPath(contractName, artifactsPath);
  }
}

// Fetch the artifact from the publish package's artifacts directory.
function getLocalArtifact(contractName: string) {
  const artifactsPath = `${__dirname}/../../artifacts/contracts`;
  return findArtifactFromPath(contractName, artifactsPath);
}

function findPathToRootOfPackage(packageName: string) {
  const packagePath = require.resolve(`${packageName}/package.json`);
  return packagePath.slice(0, packagePath.indexOf("package.json"));
}

export function findArtifactFromPath(contractName: string, artifactsPath: string) {
  const allArtifactsPaths = getAllFilesInPath(artifactsPath);
  const desiredArtifactPaths = allArtifactsPaths.filter((a) => a.endsWith(`/${contractName}.json`));

  if (desiredArtifactPaths.length !== 1)
    throw new Error(`Couldn't find desired artifact or found too many for ${contractName}`);
  return JSON.parse(fs.readFileSync(desiredArtifactPaths[0], "utf-8"));
}

export function getAllFilesInPath(dirPath: string, arrayOfFiles: string[] = []): string[] {
  const files = fs.readdirSync(dirPath);

  files.forEach((file) => {
    if (fs.statSync(dirPath + "/" + file).isDirectory())
      arrayOfFiles = getAllFilesInPath(dirPath + "/" + file, arrayOfFiles);
    else arrayOfFiles.push(path.join(dirPath, "/", file));
  });

  return arrayOfFiles;
}

export const toWei = (num: string | number | BigNumber) => ethers.utils.parseEther(num.toString());

export const toWeiWithDecimals = (num: string | number | BigNumber, decimals: number) =>
  ethers.utils.parseUnits(num.toString(), decimals);

export const toBNWei = (num: string | number | BigNumber) => BigNumber.from(toWei(num));

export const toBNWeiWithDecimals = (num: string | number | BigNumber, decimals: number) =>
  BigNumber.from(toWeiWithDecimals(num, decimals));

export const fromWei = (num: string | number | BigNumber) => ethers.utils.formatUnits(num.toString());

export const toBN = (num: string | number | BigNumber) => {
  // If the string version of the num contains a `.` then it is a number which needs to be parsed to a string int.
  if (num.toString().includes(".")) return BigNumber.from(parseInt(num.toString()));
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

export async function seedContract(
  contract: Contract,
  walletToFund: Signer,
  tokens: Contract[],
  weth: Contract | undefined,
  amountToSeedWith: number | BigNumber
) {
  await seedWallet(walletToFund, tokens, weth, amountToSeedWith);
  for (const token of tokens) await token.connect(walletToFund).transfer(contract.address, amountToSeedWith);
  if (weth) await weth.connect(walletToFund).transfer(contract.address, amountToSeedWith);
}

export function randomBigNumber(bytes = 32, signed = false) {
  const sign = signed && Math.random() < 0.5 ? "-" : "";
  const byteString = "0x" + Buffer.from(ethers.utils.randomBytes(signed ? bytes - 1 : bytes)).toString("hex");
  return ethers.BigNumber.from(sign + byteString);
}

export function randomAddress() {
  return ethers.utils.getAddress(ethers.utils.hexlify(ethers.utils.randomBytes(20)));
}

export async function getParamType(contractName: string, functionName: string, paramName: string) {
  const contractFactory = await getContractFactory(contractName, new ethers.VoidSigner(ethers.constants.AddressZero));
  const fragment = contractFactory.interface.fragments.find((fragment) => fragment.name === functionName);
  return fragment!.inputs.find((input) => input.name === paramName) || "";
}

export async function createFake(contractName: string, targetAddress: string = "") {
  const contractFactory = await getContractFactory(contractName, new ethers.VoidSigner(ethers.constants.AddressZero));
  return smock.fake(contractFactory, targetAddress !== "" ? { address: targetAddress } : undefined);
}

function avmL1ToL2Alias(l1Address: string) {
  const offset = toBN("0x1111000000000000000000000000000000001111");
  const l1AddressAsNumber = toBN(l1Address);

  const l2AddressAsNumber = l1AddressAsNumber.add(offset);

  const mask = toBN("2").pow(toBN("160"));
  return ethers.utils.hexlify(l2AddressAsNumber.mod(mask));
}

const { defaultAbiCoder, keccak256 } = ethers.utils;

export { avmL1ToL2Alias, expect, Contract, ethers, hre, BigNumber, defaultAbiCoder, keccak256, FakeContract, Signer };
