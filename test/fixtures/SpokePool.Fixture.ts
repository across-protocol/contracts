import { hre } from "../../utils/utils.hre";
import { getContractFactory, SignerWithAddress, Contract, ethers, BigNumber, defaultAbiCoder } from "../../utils/utils";

import * as consts from "../constants";
import { USSRelayerRefundLeaf } from "../MerkleLib.utils";

export const spokePoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  return await deploySpokePool(ethers);
});

// Have a separate function that deploys the contract and returns the contract addresses. This is called by the fixture
// to have standard fixture features. It is also exported as a function to enable non-snapshoted deployments.
export async function deploySpokePool(ethers: any): Promise<{
  weth: Contract;
  erc20: Contract;
  spokePool: Contract;
  unwhitelistedErc20: Contract;
  destErc20: Contract;
  erc1271: Contract;
}> {
  const [deployerWallet, crossChainAdmin, hubPool] = await ethers.getSigners();

  // Create tokens:
  const weth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const erc20 = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("USD Coin", "USDC", 18);
  await erc20.addMember(consts.TokenRolesEnum.MINTER, deployerWallet.address);
  const unwhitelistedErc20 = await (
    await getContractFactory("ExpandedERC20", deployerWallet)
  ).deploy("Unwhitelisted", "UNWHITELISTED", 18);
  await unwhitelistedErc20.addMember(consts.TokenRolesEnum.MINTER, deployerWallet.address);
  const destErc20 = await (
    await getContractFactory("ExpandedERC20", deployerWallet)
  ).deploy("L2 USD Coin", "L2 USDC", 18);
  await destErc20.addMember(consts.TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the pool
  const spokePool = await hre.upgrades.deployProxy(
    await getContractFactory("MockSpokePool", deployerWallet),
    [0, crossChainAdmin.address, hubPool.address],
    { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address] }
  );
  await spokePool.setChainId(consts.destinationChainId);

  // ERC1271
  const erc1271 = await (await getContractFactory("MockERC1271", deployerWallet)).deploy(deployerWallet.address);

  return {
    weth,
    erc20,
    spokePool,
    unwhitelistedErc20,
    destErc20,
    erc1271,
  };
}

export interface DepositRoute {
  originToken: string;
  destinationChainId?: number;
  enabled?: boolean;
}
export async function enableRoutes(spokePool: Contract, routes: DepositRoute[]) {
  for (const route of routes) {
    await spokePool.setEnableRoute(
      route.originToken,
      route.destinationChainId ?? consts.destinationChainId,
      route.enabled ?? true
    );
  }
}

export interface USSRelayData {
  depositor: string;
  recipient: string;
  exclusiveRelayer: string;
  inputToken: string;
  outputToken: string;
  inputAmount: BigNumber;
  outputAmount: BigNumber;
  originChainId: number;
  depositId: number;
  fillDeadline: number;
  exclusivityDeadline: number;
  message: string;
}

export interface USSRelayExecutionParams {
  relay: USSRelayData;
  relayHash: string;
  updatedOutputAmount: BigNumber;
  updatedRecipient: string;
  updatedMessage: string;
  repaymentChainId: number;
}

export const enum FillType {
  FastFill,
  ReplacedSlowFill,
  SlowFill,
}

export const enum FillStatus {
  Unfilled,
  RequestedSlowFill,
  Filled,
}

export interface USSSlowFill {
  relayData: USSRelayData;
  chainId: number;
  updatedOutputAmount: BigNumber;
}

export function getUSSRelayHash(relayData: USSRelayData, destinationChainId: number): string {
  return ethers.utils.keccak256(
    defaultAbiCoder.encode(
      [
        "tuple(address depositor, address recipient, address exclusiveRelayer, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 originChainId, uint32 depositId, uint32 fillDeadline, uint32 exclusivityDeadline, bytes message)",
        "uint256 destinationChainId",
      ],
      [relayData, destinationChainId]
    )
  );
}

export async function getUpdatedUSSDepositSignature(
  depositor: SignerWithAddress,
  depositId: number,
  originChainId: number,
  updatedOutputAmount: BigNumber,
  updatedRecipient: string,
  updatedMessage: string
): Promise<string> {
  const typedData = {
    types: {
      UpdateDepositDetails: [
        { name: "depositId", type: "uint32" },
        { name: "originChainId", type: "uint256" },
        { name: "updatedOutputAmount", type: "uint256" },
        { name: "updatedRecipient", type: "address" },
        { name: "updatedMessage", type: "bytes" },
      ],
    },
    domain: {
      name: "ACROSS-V2",
      version: "1.0.0",
      chainId: originChainId,
    },
    message: {
      depositId,
      originChainId,
      updatedOutputAmount,
      updatedRecipient,
      updatedMessage,
    },
  };
  return await depositor._signTypedData(typedData.domain, typedData.types, typedData.message);
}

export async function deployMockUSSSpokePoolCaller(
  spokePool: Contract,
  rootBundleId: number,
  leaf: USSRelayerRefundLeaf,
  proof: string[]
): Promise<Contract> {
  return await (
    await getContractFactory("MockUSSCaller", (await ethers.getSigners())[0])
  ).deploy(spokePool.address, rootBundleId, leaf, proof);
}
