import { TokenRolesEnum } from "@uma/common";
import { BigNumber, Contract, utils } from "ethers";
import { getContractFactory, SignerWithAddress } from "./utils";
import {
  destinationChainId,
  depositQuoteTimeBuffer,
  amountToDeposit,
  depositRelayerFeePct,
  realizedLpFeePct,
} from "./constants";
import hre from "hardhat";

const { defaultAbiCoder, keccak256, arrayify } = utils;

export const spokePoolFixture = hre.deployments.createFixture(async ({ ethers }) => {
  const [deployerWallet] = await ethers.getSigners();
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
    await getContractFactory("MockSpokePool", deployerWallet)
  ).deploy(weth.address, depositQuoteTimeBuffer, timer.address);

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
      route.destinationChainId ? route.destinationChainId : destinationChainId,
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
      token.address,
      destinationChainId,
      amountToDeposit,
      recipient.address,
      depositRelayerFeePct,
      currentSpokePoolTime
    );
}
export interface RelayData {
  depositor: string;
  recipient: string;
  destinationToken: string;
  realizedLpFeePct: string;
  relayerFeePct: string;
  depositId: string;
  originChainId: string;
  relayAmount: string;
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
): { relayHash: string; relayData: RelayData; relayDataValues: string[] } {
  const relayData = {
    depositor: _depositor,
    recipient: _recipient,
    destinationToken: _destinationToken,
    realizedLpFeePct: _realizedLpFeePct || realizedLpFeePct.toString(),
    relayerFeePct: _relayerFeePct || depositRelayerFeePct.toString(),
    depositId: _depositId.toString(),
    originChainId: _originChainId.toString(),
    relayAmount: _relayAmount || amountToDeposit.toString(),
  };
  const relayDataValues = Object.values(relayData);
  const relayHash = keccak256(
    defaultAbiCoder.encode(
      ["address", "address", "address", "uint64", "uint64", "uint64", "uint256", "uint256"],
      relayDataValues
    )
  );
  return {
    relayHash,
    relayData,
    relayDataValues,
  };
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
  const messageHash = keccak256(
    defaultAbiCoder.encode(
      ["string", "uint64", "uint64", "uint256"],
      ["ACROSS-V2-FEE-1.0", modifiedRelayerFeePct, depositId, originChainId]
    )
  );
  const signature = await depositor.signMessage(arrayify(messageHash));

  return {
    messageHash,
    signature,
  };
}
