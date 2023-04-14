import { getContractFactory, SignerWithAddress, Contract, hre, ethers, BigNumber, defaultAbiCoder } from "../utils";
import * as consts from "../constants";

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
    [0, crossChainAdmin.address, hubPool.address, weth.address],
    { kind: "uups" }
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
      route.destinationChainId ? route.destinationChainId : consts.destinationChainId,
      route.enabled !== undefined ? route.enabled : true
    );
  }
}

export async function deposit(
  spokePool: Contract,
  token: Contract,
  recipient: SignerWithAddress,
  depositor: SignerWithAddress,
  destinationChainId: number = consts.destinationChainId,
  amountToDeposit: BigNumber = consts.amountToDeposit,
  depositRelayerFeePct: BigNumber = consts.depositRelayerFeePct,
  quoteTimestamp?: number
) {
  await spokePool
    .connect(depositor)
    .deposit(
      ...getDepositParams(
        recipient.address,
        token.address,
        amountToDeposit,
        destinationChainId,
        depositRelayerFeePct,
        quoteTimestamp ?? (await spokePool.getCurrentTime())
      )
    );
  const [events, originChainId] = await Promise.all([
    spokePool.queryFilter(spokePool.filters.FundsDeposited()),
    spokePool.chainId(),
  ]);
  const lastEvent = events[events.length - 1];
  if (lastEvent.args)
    return {
      amount: lastEvent.args.amount,
      destinationChainId: Number(lastEvent.args.destinationChainId),
      relayerFeePct: lastEvent.args.relayerFeePct,
      depositId: lastEvent.args.depositId,
      quoteTimestamp: lastEvent.args.quoteTimestamp,
      originToken: lastEvent.args.originToken,
      recipient: lastEvent.args.recipient,
      depositor: lastEvent.args.depositor,
      originChainId: Number(originChainId),
    };
  return null;
}

export async function fillRelay(
  spokePool: Contract,
  destErc20: Contract | string,
  recipient: SignerWithAddress,
  depositor: SignerWithAddress,
  relayer: SignerWithAddress,
  depositId: number = consts.firstDepositId,
  originChainId: number = consts.originChainId,
  depositAmount: BigNumber = consts.amountToDeposit,
  amountToRelay: BigNumber = consts.amountToRelay,
  realizedLpFeePct: BigNumber = consts.realizedLpFeePct,
  relayerFeePct: BigNumber = consts.depositRelayerFeePct
) {
  await spokePool
    .connect(relayer)
    .fillRelay(
      ...getFillRelayParams(
        getRelayHash(
          depositor.address,
          recipient.address,
          depositId,
          originChainId,
          consts.destinationChainId,
          (destErc20 as Contract).address ?? (destErc20 as string),
          depositAmount,
          realizedLpFeePct,
          relayerFeePct
        ).relayData,
        amountToRelay,
        consts.repaymentChainId
      )
    );
  const [events, destinationChainId] = await Promise.all([
    spokePool.queryFilter(spokePool.filters.FilledRelay()),
    spokePool.chainId(),
  ]);
  const lastEvent = events[events.length - 1];
  if (lastEvent.args)
    return {
      amount: lastEvent.args.amount,
      totalFilledAmount: lastEvent.args.totalFilledAmount,
      fillAmount: lastEvent.args.fillAmount,
      repaymentChainId: Number(lastEvent.args.repaymentChainId),
      originChainId: Number(lastEvent.args.originChainId),
      relayerFeePct: lastEvent.args.relayerFeePct,
      appliedRelayerFeePct: lastEvent.args.appliedRelayerFeePct,
      realizedLpFeePct: lastEvent.args.realizedLpFeePct,
      depositId: lastEvent.args.depositId,
      destinationToken: lastEvent.args.destinationToken,
      relayer: lastEvent.args.relayer,
      depositor: lastEvent.args.depositor,
      recipient: lastEvent.args.recipient,
      isSlowRelay: lastEvent.args.isSlowRelay,
      destinationChainId: Number(destinationChainId),
    };
  else return null;
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

export interface SlowFill {
  relayData: RelayData;
  payoutAdjustmentPct: BigNumber;
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

export function getDepositParams(
  _recipient: string,
  _originToken: string,
  _amount: BigNumber,
  _destinationChainId: number,
  _relayerFeePct: BigNumber,
  _quoteTime: BigNumber,
  _maxCount?: BigNumber
): string[] {
  return [
    _recipient,
    _originToken,
    _amount.toString(),
    _destinationChainId.toString(),
    _relayerFeePct.toString(),
    _quoteTime.toString(),
    "0x",
    _maxCount ? _maxCount.toString() : consts.maxUint256.toString(),
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
