import { hre } from "../../../../utils/utils.hre";
import {
  getContractFactory,
  randomAddress,
  SignerWithAddress,
  Contract,
  ethers,
  BigNumber,
  defaultAbiCoder,
} from "../../../../utils/utils";

import * as consts from "../constants";
import { RelayerRefundLeaf } from "../MerkleLib.utils";

export const spokePoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  return await deploySpokePool(ethers);
});

// Silence warnings from openzeppelin/hardhat-upgrades for this fixture.
hre.upgrades.silenceWarnings();

// Have a separate function that deploys the contract and returns the contract addresses. This is called by the fixture
// to have standard fixture features. It is also exported as a function to enable non-snapshoted deployments.
export async function deploySpokePool(
  ethers: any,
  spokePoolName = "MockSpokePool"
): Promise<{
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
    await getContractFactory("ExpandedERC20WithBlacklist", deployerWallet)
  ).deploy("L2 USD Coin", "L2 USDC", 18);
  await destErc20.addMember(consts.TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the pool
  const spokePool = await hre.upgrades.deployProxy(
    await getContractFactory(spokePoolName, deployerWallet),
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

export interface RelayData {
  depositor: string;
  recipient: string;
  destinationToken: string;
  amount: BigNumber;
  realizedLpFeePct: BigNumber;
  relayerFeePct: BigNumber;
  depositId: string;
  originChainId: string;
  destinationChainId: string;
  message: string;
}

export interface V3RelayData {
  depositor: string;
  recipient: string;
  exclusiveRelayer: string;
  inputToken: string;
  outputToken: string;
  inputAmount: BigNumber;
  outputAmount: BigNumber;
  originChainId: number;
  depositId: BigNumber;
  fillDeadline: number;
  exclusivityDeadline: number;
  message: string;
}

export interface V3RelayExecutionParams {
  relay: V3RelayData;
  relayHash: string;
  updatedOutputAmount: BigNumber;
  updatedRecipient: string;
  updatedMessage: string;
  repaymentChainId: number;
}

export const enum FillType {
  FastFill = 0,
  ReplacedSlowFill,
  SlowFill,
}

export const enum FillStatus {
  Unfilled = 0,
  RequestedSlowFill,
  Filled,
}

export interface SlowFill {
  relayData: RelayData;
  payoutAdjustmentPct: BigNumber;
}

export interface V3SlowFill {
  relayData: V3RelayData;
  chainId: number;
  updatedOutputAmount: BigNumber;
}

export function getRelayHash(
  _depositor: string,
  _recipient: string,
  _depositId: number,
  _originChainId: number,
  _destinationChainId: number,
  _destinationToken: string,
  _amount?: BigNumber,
  _realizedLpFeePct?: BigNumber,
  _relayerFeePct?: BigNumber,
  _message?: string
): { relayHash: string; relayData: RelayData } {
  const relayData = {
    depositor: _depositor,
    recipient: _recipient,
    destinationToken: _destinationToken,
    amount: _amount || consts.amountToDeposit,
    originChainId: _originChainId.toString(),
    destinationChainId: _destinationChainId.toString(),
    realizedLpFeePct: _realizedLpFeePct || consts.realizedLpFeePct,
    relayerFeePct: _relayerFeePct || consts.depositRelayerFeePct,
    depositId: _depositId.toString(),
    message: _message || "0x",
  };

  const relayHash = ethers.utils.keccak256(
    defaultAbiCoder.encode(
      [
        "tuple(address depositor, address recipient, address destinationToken, uint256 amount, uint256 originChainId, uint256 destinationChainId, int64 realizedLpFeePct, int64 relayerFeePct, uint32 depositId, bytes message)",
      ],
      [relayData]
    )
  );
  return { relayHash, relayData };
}

export function getV3RelayHash(relayData: V3RelayData, destinationChainId: number): string {
  return ethers.utils.keccak256(
    defaultAbiCoder.encode(
      [
        "tuple(bytes32 depositor, bytes32 recipient, bytes32 exclusiveRelayer, bytes32 inputToken, bytes32 outputToken, uint256 inputAmount, uint256 outputAmount, uint256 originChainId, uint256 depositId, uint32 fillDeadline, uint32 exclusivityDeadline, bytes message)",
        "uint256 destinationChainId",
      ],
      [relayData, destinationChainId]
    )
  );
}

// @todo we likely don't need to keep this function around for too long but its useful for making sure that the new relay hash is identical to the
// legacy one.
export function getLegacyV3RelayHash(relayData: V3RelayData, destinationChainId: number): string {
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

export function getDepositParams(args: {
  recipient?: string;
  originToken: string;
  amount: BigNumber;
  destinationChainId: number;
  relayerFeePct: BigNumber;
  quoteTimestamp: number;
  message?: string;
  maxCount?: BigNumber;
}): string[] {
  return [
    args.recipient ?? randomAddress(),
    args.originToken,
    args.amount.toString(),
    args.destinationChainId.toString(),
    args.relayerFeePct.toString(),
    args.quoteTimestamp.toString(),
    args.message ?? "0x",
    args?.maxCount?.toString() ?? consts.maxUint256.toString(),
  ];
}

export function getFillRelayParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _repaymentChain?: number,
  _maxCount?: BigNumber
): string[] {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _relayData.destinationToken,
    _relayData.amount.toString(),
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct.toString(),
    _relayData.relayerFeePct.toString(),
    _relayData.depositId,
    _relayData.message || "0x",
    _maxCount ? _maxCount.toString() : consts.maxUint256.toString(),
  ];
}

export function getFillRelayUpdatedFeeParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _updatedFee: BigNumber,
  _signature: string,
  _repaymentChain?: number,
  _updatedRecipient?: string,
  _updatedMessage?: string,
  _maxCount?: BigNumber
): string[] {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _updatedRecipient || _relayData.recipient,
    _relayData.destinationToken,
    _relayData.amount.toString(),
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct.toString(),
    _relayData.relayerFeePct.toString(),
    _updatedFee.toString(),
    _relayData.depositId,
    _relayData.message,
    _updatedMessage || _relayData.message,
    _signature,
    _maxCount ? _maxCount.toString() : consts.maxUint256.toString(),
  ];
}

export function getExecuteSlowRelayParams(
  _depositor: string,
  _recipient: string,
  _destToken: string,
  _amount: BigNumber,
  _originChainId: number,
  _realizedLpFeePct: BigNumber,
  _relayerFeePct: BigNumber,
  _depositId: number,
  _relayerRefundId: number,
  _message: string,
  _payoutAdjustment: BigNumber,
  _proof: string[]
): (string | string[])[] {
  return [
    _depositor,
    _recipient,
    _destToken,
    _amount.toString(),
    _originChainId.toString(),
    _realizedLpFeePct.toString(),
    _relayerFeePct.toString(),
    _depositId.toString(),
    _relayerRefundId.toString(),
    _message,
    _payoutAdjustment.toString(),
    _proof,
  ];
}

export interface UpdatedRelayerFeeData {
  newRelayerFeePct: string;
  depositorMessageHash: string;
  depositorSignature: string;
}
export async function modifyRelayHelper(
  modifiedRelayerFeePct: BigNumber,
  depositId: string,
  originChainId: string,
  depositor: SignerWithAddress,
  updatedRecipient: string,
  updatedMessage: string
): Promise<{ signature: string }> {
  const typedData = {
    types: {
      UpdateDepositDetails: [
        { name: "depositId", type: "uint32" },
        { name: "originChainId", type: "uint256" },
        { name: "updatedRelayerFeePct", type: "int64" },
        { name: "updatedRecipient", type: "address" },
        { name: "updatedMessage", type: "bytes" },
      ],
    },
    domain: {
      name: "ACROSS-V2",
      version: "1.0.0",
      chainId: Number(originChainId),
    },
    message: {
      depositId,
      originChainId,
      updatedRelayerFeePct: modifiedRelayerFeePct,
      updatedRecipient,
      updatedMessage,
    },
  };
  const signature = await depositor._signTypedData(typedData.domain, typedData.types, typedData.message);
  return {
    signature,
  };
}

export async function getUpdatedV3DepositSignature(
  depositor: SignerWithAddress,
  depositId: BigNumber,
  originChainId: number,
  updatedOutputAmount: BigNumber,
  updatedRecipient: string,
  updatedMessage: string
): Promise<string> {
  const typedData = {
    types: {
      UpdateDepositDetails: [
        { name: "depositId", type: "uint256" },
        { name: "originChainId", type: "uint256" },
        { name: "updatedOutputAmount", type: "uint256" },
        { name: "updatedRecipient", type: "bytes32" },
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

export async function deployMockSpokePoolCaller(
  spokePool: Contract,
  rootBundleId: number,
  leaf: RelayerRefundLeaf,
  proof: string[]
): Promise<Contract> {
  return await (
    await getContractFactory("MockCaller", (await ethers.getSigners())[0])
  ).deploy(spokePool.address, rootBundleId, leaf, proof);
}
