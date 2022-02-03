import { TokenRolesEnum } from "@uma/common";
import { Contract, utils } from "ethers";
import { getContractFactory, SignerWithAddress } from "./utils";
import {
  destinationChainId,
  depositQuoteTimeBuffer,
  amountToDeposit,
  depositRelayerFeePct,
  realizedLpFeePct,
} from "./constants";
import hre from "hardhat";

const { defaultAbiCoder, keccak256 } = utils;

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
export function getRelayHash(
  sender: string,
  recipient: string,
  depositId: number,
  originChainId: number,
  destinationToken: string,
  relayAmount?: string,
  _realizedLpFeePct?: string,
  relayerFeePct?: string
): { relayHash: string; relayData: string[] } {
  const relayData = [
    sender,
    recipient,
    destinationToken,
    _realizedLpFeePct || realizedLpFeePct.toString(),
    relayerFeePct || depositRelayerFeePct.toString(),
    depositId.toString(),
    originChainId.toString(),
    relayAmount || amountToDeposit.toString(),
  ];
  const relayHash = keccak256(
    defaultAbiCoder.encode(
      ["address", "address", "address", "uint64", "uint64", "uint64", "uint256", "uint256"],
      relayData
    )
  );
  return {
    relayHash,
    relayData,
  };
}
