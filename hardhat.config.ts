import * as dotenv from "dotenv";

import { HardhatUserConfig } from "hardhat/config";
import { getNodeUrl, getMnemonic } from "@uma/common";

import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-deploy";

dotenv.config();

const solcVersion = "0.8.13";
const mnemonic = getMnemonic();

// Compilation settings are overridden for large contracts to allow them to compile without going over the bytecode
// limit.
const LARGE_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true },
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [{ version: solcVersion, settings: { optimizer: { enabled: true, runs: 1000000 }, viaIR: true } }],
    overrides: {
      "contracts/HubPool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
    },
  },
  networks: {
    hardhat: { accounts: { accountsBalance: "1000000000000000000000000" } },
    kovan: {
      url: getNodeUrl("kovan", true, 42),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: 42,
    },
    "optimism-kovan": {
      url: getNodeUrl("optimism-kovan", true, 69),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: 69,
      companionNetworks: { l1: "kovan" },
    },
    optimism: {
      url: getNodeUrl("optimism", true, 10),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: 10,
      companionNetworks: { l1: "mainnet" },
    },
    arbitrum: {
      chainId: 42161,
      url: getNodeUrl("arbitrum", true, 42161),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "arbitrum-rinkeby": {
      chainId: 421611,
      url: getNodeUrl("arbitrum-rinkeby", true, 421611),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "rinkeby" },
    },
    rinkeby: {
      chainId: 4,
      url: getNodeUrl("rinkeby", true, 4),
      saveDeployments: true,
      accounts: { mnemonic },
    },
    goerli: {
      chainId: 5,
      url: getNodeUrl("goerli", true, 5),
      saveDeployments: true,
      accounts: { mnemonic },
    },
    polygon: {
      chainId: 137,
      url: getNodeUrl("polygon-matic", true, 137),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "polygon-mumbai": {
      chainId: 80001,
      url: getNodeUrl("polygon-mumbai", true, 80001),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "goerli" },
    },
  },
  gasReporter: { enabled: process.env.REPORT_GAS !== undefined, currency: "USD" },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      kovan: process.env.ETHERSCAN_API_KEY,
      rinkeby: process.env.ETHERSCAN_API_KEY,
      goerli: process.env.ETHERSCAN_API_KEY,
      optimisticEthereum: process.env.OPTIMISM_ETHERSCAN_API_KEY,
      optimisticKovan: process.env.OPTIMISM_ETHERSCAN_API_KEY,
      arbitrumOne: process.env.ARBITRUM_ETHERSCAN_API_KEY,
      arbitrumTestnet: process.env.ARBITRUM_ETHERSCAN_API_KEY,
      polygon: process.env.POLYGON_ETHERSCAN_API_KEY,
      polygonMumbai: process.env.POLYGON_ETHERSCAN_API_KEY,
    },
  },
  namedAccounts: { deployer: 0 },
};

export default config;
