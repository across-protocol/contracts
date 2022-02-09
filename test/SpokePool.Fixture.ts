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
  const merkleLib = await (await getContractFactory("MerkleLib", deployerWallet)).deploy();
  const spokePool = await (
    await getContractFactory("MockSpokePool", { signer: deployerWallet, libraries: { MerkleLib: merkleLib.address } })
  ).deploy(crossChainAdmin.address, hubPool.address, weth.address, consts.depositQuoteTimeBuffer, timer.address);

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
      token.address,
      consts.destinationChainId,
      consts.amountToDeposit,
      recipient.address,
      consts.depositRelayerFeePct,
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
    realizedLpFeePct: _realizedLpFeePct || consts.realizedLpFeePct.toString(),
    relayerFeePct: _relayerFeePct || consts.depositRelayerFeePct.toString(),
    depositId: _depositId.toString(),
    originChainId: _originChainId.toString(),
    relayAmount: _relayAmount || consts.amountToDeposit.toString(),
  };
  const relayDataValues = Object.values(relayData);
  const relayHash = ethers.utils.keccak256(
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
  const messageHash = ethers.utils.keccak256(
    defaultAbiCoder.encode(
      ["string", "uint64", "uint64", "uint256"],
      ["ACROSS-V2-FEE-1.0", modifiedRelayerFeePct, depositId, originChainId]
    )
  );
  const signature = await depositor.signMessage(ethers.utils.arrayify(messageHash));

  return {
    messageHash,
    signature,
  };
}
