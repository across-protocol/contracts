import { SignerWithAddress, Contract, BigNumber } from "../utils";
export declare const spokePoolFixture: (options?: unknown) => Promise<{
  timer: Contract;
  weth: Contract;
  erc20: Contract;
  spokePool: Contract;
  unwhitelistedErc20: Contract;
  destErc20: Contract;
}>;
export interface DepositRoute {
  originToken: string;
  destinationChainId?: number;
  enabled?: boolean;
}
export declare function enableRoutes(spokePool: Contract, routes: DepositRoute[]): Promise<void>;
export declare function deposit(
  spokePool: Contract,
  token: Contract,
  recipient: SignerWithAddress,
  depositor: SignerWithAddress
): Promise<void>;
export interface RelayData {
  depositor: string;
  recipient: string;
  destinationToken: string;
  amount: string;
  realizedLpFeePct: string;
  relayerFeePct: string;
  depositId: string;
  originChainId: string;
}
export declare function getRelayHash(
  _depositor: string,
  _recipient: string,
  _depositId: number,
  _originChainId: number,
  _destinationToken: string,
  _amount?: string,
  _realizedLpFeePct?: string,
  _relayerFeePct?: string
): {
  relayHash: string;
  relayData: RelayData;
};
export declare function getDepositParams(
  _recipient: string,
  _originToken: string,
  _amount: BigNumber,
  _destinationChainId: number,
  _relayerFeePct: BigNumber,
  _quoteTime: BigNumber
): string[];
export declare function getFillRelayParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _repaymentChain?: number
): string[];
export declare function getFillRelayUpdatedFeeParams(
  _relayData: RelayData,
  _maxTokensToSend: BigNumber,
  _updatedFee: BigNumber,
  _signature: string,
  _repaymentChain?: number
): string[];
export declare function getExecuteSlowRelayParams(
  _depositor: string,
  _recipient: string,
  _destToken: string,
  _amount: BigNumber,
  _originChainId: number,
  _realizedLpFeePct: BigNumber,
  _relayerFeePct: BigNumber,
  _depositId: number,
  _relayerRefundId: number,
  _proof: string[]
): (string | string[])[];
export interface UpdatedRelayerFeeData {
  newRelayerFeePct: string;
  depositorMessageHash: string;
  depositorSignature: string;
}
export declare function modifyRelayHelper(
  modifiedRelayerFeePct: BigNumber,
  depositId: string,
  originChainId: string,
  depositor: SignerWithAddress
): Promise<{
  messageHash: string;
  signature: string;
}>;
