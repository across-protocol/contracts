import { Contract, Signer } from "../utils";
export declare const hubPoolFixture: (options?: unknown) => Promise<{
  timer: Contract;
  finder: Contract;
  collateralWhitelist: Contract;
  identifierWhitelist: Contract;
  store: Contract;
  optimisticOracle: Contract;
  hubPool: Contract;
  mockAdapter: Contract;
  mockSpoke: Contract;
  crossChainAdmin: import("@nomiclabs/hardhat-ethers/signers").SignerWithAddress;
  l2Weth: string;
  l2Dai: string;
  l2Usdc: string;
  weth: Contract;
  usdc: Contract;
  dai: Contract;
}>;
export declare function enableTokensForLP(
  owner: Signer,
  hubPool: Contract,
  weth: Contract,
  tokens: Contract[]
): Promise<Contract[]>;
