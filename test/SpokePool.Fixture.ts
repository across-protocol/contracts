import { TokenRolesEnum } from "@uma/common";

import { getContractFactory, SignerWithAddress, Contract, hre, ethers, BigNumber, defaultAbiCoder } from "./utils";
import * as consts from "./constants";

export const spokePoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  const [deployerWallet, crossChainAdmin, hubPool] = await ethers.getSigners();
  // Useful contracts.
  const timer = await (await getContractFactory("Timer", deployerWallet)).deploy();

  // Create tokens:
  const weth = await (await getContractFactory("WETH9", deployerWallet)).deploy();
  const erc20 = await (await getContractFactory("ExpandedERC20", deployerWallet)).deploy("USD Coin", "USDC", 18);
  await erc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);
  const unwhitelistedErc20 = await (
    await getContractFactory("ExpandedERC20", deployerWallet)
  ).deploy("Unwhitelisted", "UNWHITELISTED", 18);
  await unwhitelistedErc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);
  const destErc20 = await (
    await getContractFactory("ExpandedERC20", deployerWallet)
  ).deploy("L2 USD Coin", "L2 USDC", 18);
  await destErc20.addMember(TokenRolesEnum.MINTER, deployerWallet.address);

  // Deploy the pool
  const spokePool = await (
    await getContractFactory("MockSpokePool", { signer: deployerWallet })
  ).deploy(crossChainAdmin.address, hubPool.address, weth.address, timer.address);

  return { timer, weth, erc20, spokePool, unwhitelistedErc20, destErc20 };
});

export interface DepositRoute {
  originToken: string;
  destinationChainId?: number;
  enabled?: boolean;
}
export async function enableRoutes(spokePool: Contract, routes: DepositRoute[]) {
  for (const route of routes) {
    await spokePool.setEnableRoute(
      route.originToken,
      route.destinationChainId ? route.destinationChainId : consts.destinationChainId,
      route.enabled !== undefined ? route.enabled : true
    );
  }
}

export async function deposit(
  spokePool: Contract,
  token: Contract,
  recipient: SignerWithAddress,
  depositor: SignerWithAddress
) {
  const currentSpokePoolTime = await spokePool.getCurrentTime();
  await spokePool
    .connect(depositor)
    .deposit(
      recipient.address,
      token.address,
      consts.amountToDeposit,
      consts.depositRelayerFeePct,
      consts.destinationChainId,
      currentSpokePoolTime
    );
}
export interface RelayData {
  depositor: string;
  recipient: string;
  destinationToken: string;
  relayAmount: string;
  realizedLpFeePct: string;
  relayerFeePct: string;
  depositId: string;
  originChainId: string;
}
export function getRelayHash(
  _depositor: string,
  _recipient: string,
  _depositId: number,
  _originChainId: number,
  _destinationToken: string,
  _relayAmount?: string,
  _realizedLpFeePct?: string,
  _relayerFeePct?: string
): { relayHash: string; relayData: RelayData } {
  const relayData = {
    depositor: _depositor,
    recipient: _recipient,
    destinationToken: _destinationToken,
    relayAmount: _relayAmount || consts.amountToDeposit.toString(),
    originChainId: _originChainId.toString(),
    realizedLpFeePct: _realizedLpFeePct || consts.realizedLpFeePct.toString(),
    relayerFeePct: _relayerFeePct || consts.depositRelayerFeePct.toString(),
    depositId: _depositId.toString(),
  };
  const relayHash = ethers.utils.keccak256(
    defaultAbiCoder.encode(
      ["address", "address", "address", "uint256", "uint256", "uint64", "uint64", "uint32"],
      Object.values(relayData)
    )
  );
  return {
    relayHash,
    relayData,
  };
}

export function getDepositParams(
  _recipient: string,
  _originToken: string,
  _amount: BigNumber,
  _destinationChainId: number,
  _relayerFeePct: BigNumber,
  _quoteTime: BigNumber
): string[] {
  return [
    _recipient,
    _originToken,
    _amount.toString(),
    _destinationChainId.toString(),
    _relayerFeePct.toString(),
    _quoteTime.toString(),
  ];
}

export function getFillRelayParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _repaymentChain?: number
): string[] {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _relayData.destinationToken,
    _relayData.relayAmount,
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct,
    _relayData.relayerFeePct,
    _relayData.depositId,
  ];
}

export function getFillRelayUpdatedFeeParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _updatedFee: BigNumber,
  _signature: string,
  _repaymentChain?: number
): string[] {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _relayData.destinationToken,
    _relayData.relayAmount,
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct,
    _relayData.relayerFeePct,
    _updatedFee.toString(),
    _relayData.depositId,
    _signature,
  ];
}

export function getExecuteSlowRelayParams(
  _depositor: string,
  _recipient: string,
  _destToken: string,
  _amountToRelay: BigNumber,
  _originChainId: number,
  _realizedLpFeePct: BigNumber,
  _relayerFeePct: BigNumber,
  _depositId: number,
  _relayerRefundId: number,
  _proof: string[]
): (string | string[])[] {
  return [
    _depositor,
    _recipient,
    _destToken,
    _amountToRelay.toString(),
    _originChainId.toString(),
    _realizedLpFeePct.toString(),
    _relayerFeePct.toString(),
    _depositId.toString(),
    _relayerRefundId.toString(),
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
  depositor: SignerWithAddress
): Promise<{ messageHash: string; signature: string }> {
  const messageHash = ethers.utils.keccak256(
    defaultAbiCoder.encode(
      ["string", "uint64", "uint32", "uint32"],
      ["ACROSS-V2-FEE-1.0", modifiedRelayerFeePct, depositId, originChainId]
    )
  );
  const signature = await depositor.signMessage(ethers.utils.arrayify(messageHash));

  return {
    messageHash,
    signature,
  };
}
