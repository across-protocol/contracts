import * as dotenv from "dotenv";

import { HardhatUserConfig } from "hardhat/config";
import { getNodeUrl, getMnemonic } from "@uma/common";
import { CHAIN_IDs } from "./utils/constants";

import "@nomicfoundation/hardhat-verify"; // Must be above hardhat-upgrades
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import "@matterlabs/hardhat-zksync-upgradable";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-deploy";
import "@openzeppelin/hardhat-upgrades";

// Custom tasks to add to HRE.
const tasks = [
  "enableL1TokenAcrossEcosystem",
  "finalizeScrollClaims",
  "rescueStuckScrollTxn",
  "verifySpokePool",
  "evmRelayMessageWithdrawal",
  "testChainAdapter",
  "upgradeSpokePool",
];

// eslint-disable-next-line node/no-missing-require
tasks.forEach((task) => require(`./tasks/${task}`));

dotenv.config();

const isTest = process.env.IS_TEST === "true" || process.env.CI === "true";

// To compile with zksolc, `hardhat` must be the default network and its `zksync` property must be true.
// So we allow the caller to set this environment variable to toggle compiling zk contracts or not.
// TODO: Figure out way to only compile specific contracts intended to be deployed on ZkSync (e.g. ZkSync_SpokePool) if
// the following config is true.
const compileZk = process.env.COMPILE_ZK === "true";

const solcVersion = "0.8.23";
const mnemonic = getMnemonic();

// Compilation settings are overridden for large contracts to allow them to compile without going over the bytecode
// limit.
const LARGE_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 1000 },
    viaIR: true,
    debug: { revertStrings: isTest ? "default" : "strip" },
  },
};
const DEFAULT_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 1000000 },
    viaIR: true,
    // Only strip revert strings if not testing or in ci.
    debug: { revertStrings: isTest ? "default" : "strip" },
  },
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [DEFAULT_CONTRACT_COMPILER_SETTINGS],
    overrides: {
      "contracts/HubPool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Linea_SpokePool.sol": {
        ...DEFAULT_CONTRACT_COMPILER_SETTINGS,
        // NOTE: Linea only supports 0.8.19.
        // See https://docs.linea.build/build-on-linea/ethereum-differences#evm-opcodes
        version: "0.8.19",
      },
      "contracts/SpokePoolVerifier.sol": {
        ...DEFAULT_CONTRACT_COMPILER_SETTINGS,
        // NOTE: Linea only supports 0.8.19.
        // See https://docs.linea.build/build-on-linea/ethereum-differences#evm-opcodes
        version: "0.8.19",
      },
      "contracts/Blast_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Lisk_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Redstone_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Zora_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Mode_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Base_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Optimism_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/WorldChain_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
    },
  },
  zksolc: {
    version: "latest",
    settings: {
      optimizer: {
        enabled: true,
      },
    },
  },
  networks: {
    hardhat: {
      accounts: { accountsBalance: "1000000000000000000000000" },
      zksync: compileZk,
      allowUnlimitedContractSize: true,
    },
    mainnet: {
      url: getNodeUrl("mainnet", true, 1),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: CHAIN_IDs.MAINNET,
      companionNetworks: { l1: "mainnet" },
    },
    zksync: {
      chainId: CHAIN_IDs.ZK_SYNC,
      url: "https://mainnet.era.zksync.io",
      saveDeployments: true,
      accounts: { mnemonic },
      ethNetwork: "mainnet",
      companionNetworks: { l1: "mainnet" },
      zksync: true,
      verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
    },
    optimism: {
      url: getNodeUrl("optimism-mainnet", true, CHAIN_IDs.OPTIMISM),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: CHAIN_IDs.OPTIMISM,
      companionNetworks: { l1: "mainnet" },
    },
    "optimism-sepolia": {
      url: getNodeUrl("optimism-sepolia", true, CHAIN_IDs.OPTIMISM_SEPOLIA),
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: CHAIN_IDs.OPTIMISM_SEPOLIA,
      companionNetworks: { l1: "sepolia" },
    },
    arbitrum: {
      chainId: CHAIN_IDs.ARBITRUM,
      url: getNodeUrl("arbitrum-mainnet", true, CHAIN_IDs.ARBITRUM),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "arbitrum-sepolia": {
      chainId: CHAIN_IDs.ARBITRUM_SEPOLIA,
      url: getNodeUrl("arbitrum-sepolia", true, CHAIN_IDs.ARBITRUM_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: { mnemonic },
      saveDeployments: true,
      chainId: CHAIN_IDs.SEPOLIA,
      companionNetworks: { l1: "sepolia" },
    },
    polygon: {
      chainId: CHAIN_IDs.POLYGON,
      url: getNodeUrl("polygon-mainnet", true, CHAIN_IDs.POLYGON),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    boba: {
      chainId: CHAIN_IDs.BOBA,
      url: getNodeUrl("boba", true, CHAIN_IDs.BOBA),
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "polygon-amoy": {
      chainId: CHAIN_IDs.POLYGON_AMOY,
      url: "https://rpc-amoy.polygon.technology",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    base: {
      chainId: CHAIN_IDs.BASE,
      url: "https://mainnet.base.org",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "base-sepolia": {
      chainId: CHAIN_IDs.BASE_SEPOLIA,
      url: `https://base-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    linea: {
      chainId: CHAIN_IDs.LINEA,
      url: `https://linea-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    scroll: {
      chainId: CHAIN_IDs.SCROLL,
      url: "https://rpc.scroll.io",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "scroll-sepolia": {
      chainId: CHAIN_IDs.SCROLL_SEPOLIA,
      url: "https://sepolia-rpc.scroll.io",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    "polygon-zk-evm": {
      chainId: 1101,
      url: "https://zkevm-rpc.com",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "polygon-zk-evm-testnet": {
      chainId: 1442,
      url: "https://rpc.public.zkevm-test.net",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "goerli" },
    },
    mode: {
      chainId: CHAIN_IDs.MODE,
      url: "https://mainnet.mode.network",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "mode-sepolia": {
      chainId: CHAIN_IDs.MODE_SEPOLIA,
      url: "https://sepolia.mode.network",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    lisk: {
      chainId: CHAIN_IDs.LISK,
      url: "https://rpc.api.lisk.com",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "lisk-sepolia": {
      chainId: CHAIN_IDs.LISK_SEPOLIA,
      url: "https://rpc.sepolia-api.lisk.com",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    redstone: {
      chainId: CHAIN_IDs.REDSTONE,
      url: "https://rpc.redstonechain.com",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    blast: {
      chainId: CHAIN_IDs.BLAST,
      url: "https://rpc.blast.io",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    "blast-sepolia": {
      chainId: CHAIN_IDs.BLAST_SEPOLIA,
      url: "https://sepolia.blast.io",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    worldchain: {
      chainId: CHAIN_IDs.WORLD_CHAIN,
      url: "https://worldchain-mainnet.g.alchemy.com/public",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    zora: {
      chainId: CHAIN_IDs.ZORA,
      url: "https://rpc.zora.energy",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
    alephzero: {
      chainId: CHAIN_IDs.ALEPH_ZERO,
      url: "https://rpc.alephzero.raas.gelato.cloud",
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
    },
  },
  gasReporter: { enabled: process.env.REPORT_GAS !== undefined, currency: "USD" },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY!,
      sepolia: process.env.ETHERSCAN_API_KEY!,
      optimisticEthereum: process.env.OPTIMISM_ETHERSCAN_API_KEY!,
      optimisticSepolia: process.env.OPTIMISM_ETHERSCAN_API_KEY!,
      arbitrumOne: process.env.ARBITRUM_ETHERSCAN_API_KEY!,
      "arbitrum-sepolia": process.env.ARBITRUM_ETHERSCAN_API_KEY!,
      polygon: process.env.POLYGON_ETHERSCAN_API_KEY!,
      "polygon-amoy": process.env.POLYGON_ETHERSCAN_API_KEY!,
      base: process.env.BASE_ETHERSCAN_API_KEY!,
      "base-sepolia": process.env.BASE_ETHERSCAN_API_KEY!,
      linea: process.env.LINEA_ETHERSCAN_API_KEY!,
      scroll: process.env.SCROLL_ETHERSCAN_API_KEY!,
      "scroll-sepolia": process.env.SCROLL_ETHERSCAN_API_KEY!,
      "polygon-zk-evm": process.env.POLYGON_ZK_EVM_ETHERSCAN_API_KEY!,
      "polygon-zk-evm-testnet": process.env.POLYGON_ZK_EVM_ETHERSCAN_API_KEY!,
      mode: process.env.MODE_ETHERSCAN_API_KEY!,
      "mode-sepolia": process.env.MODE_ETHERSCAN_API_KEY!,
      lisk: process.env.LISK_ETHERSCAN_API_KEY!,
      "lisk-sepolia": process.env.LISK_ETHERSCAN_API_KEY!,
      redstone: process.env.REDSTONE_ETHERSCAN_API_KEY!,
      blast: process.env.BLAST_ETHERSCAN_API_KEY!,
      "blast-sepolia": process.env.BLAST_ETHERSCAN_API_KEY!,
      zora: "routescan",
      worldchain: "blockscout",
      alephzero: "blockscout",
    },
    customChains: [
      {
        network: "alephzero",
        chainId: CHAIN_IDs.ALEPH_ZERO,
        urls: {
          apiURL: "https://evm-explorer.alephzero.org/api",
          browserURL: "https://evm-explorer.alephzero.org",
        },
      },
      {
        network: "base",
        chainId: CHAIN_IDs.BASE,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "base-sepolia",
        chainId: CHAIN_IDs.BASE_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
      {
        network: "linea",
        chainId: CHAIN_IDs.LINEA,
        urls: {
          apiURL: "https://api.lineascan.build/api",
          browserURL: "https://lineascan.org",
        },
      },
      {
        network: "sepolia",
        chainId: CHAIN_IDs.SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.etherscan.io/api",
          browserURL: "https://sepolia.etherscan.io",
        },
      },
      {
        network: "scroll",
        chainId: CHAIN_IDs.SCROLL,
        urls: {
          apiURL: "https://api.scrollscan.com/api",
          browserURL: "https://api.scrollscan.com",
        },
      },
      {
        network: "scroll-sepolia",
        chainId: CHAIN_IDs.SCROLL_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.scrollscan.com/api",
          browserURL: "https://api-sepolia.scrollscan.com",
        },
      },
      {
        network: "optimisticSepolia",
        chainId: CHAIN_IDs.OPTIMISM_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia-optimistic.etherscan.io/api",
          browserURL: "https://sepolia-optimism.etherscan.io",
        },
      },
      {
        network: "polygon-zk-evm",
        chainId: 1101,
        urls: {
          apiURL: "https://api-zkevm.polygonscan.com/api",
          browserURL: "https://zkevm.polygonscan.com",
        },
      },
      {
        network: "polygon-zk-evm-testnet",
        chainId: 1442,
        urls: {
          apiURL: "https://api-testnet-zkevm.polygonscan.com/api",
          browserURL: "https://testnet-zkevm.polygonscan.com/",
        },
      },
      {
        network: "polygon-amoy",
        chainId: CHAIN_IDs.POLYGON_AMOY,
        urls: {
          apiURL: "https://api-amoy.polygonscan.com/api",
          browserURL: "https://amoy.polygonscan.com",
        },
      },
      {
        network: "arbitrum-sepolia",
        chainId: CHAIN_IDs.ARBITRUM_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io",
        },
      },
      {
        network: "mode-sepolia",
        chainId: CHAIN_IDs.MODE_SEPOLIA,
        urls: {
          apiURL: "https://api.routescan.io/v2/network/testnet/evm/919/etherscan",
          browserURL: "https://testnet.modescan.io",
        },
      },
      {
        network: "mode",
        chainId: CHAIN_IDs.MODE,
        urls: {
          apiURL: "https://explorer.mode.network/api",
          browserURL: "https://explorer.mode.network/",
        },
      },
      {
        network: "lisk",
        chainId: CHAIN_IDs.LISK,
        urls: {
          apiURL: "https://blockscout.lisk.com/api",
          browserURL: "https://blockscout.lisk.com",
        },
      },
      {
        network: "lisk-sepolia",
        chainId: CHAIN_IDs.LISK_SEPOLIA,
        urls: {
          apiURL: "https://sepolia-blockscout.lisk.com/api",
          browserURL: "https://sepolia-blockscout.lisk.com",
        },
      },
      {
        network: "redstone",
        chainId: CHAIN_IDs.REDSTONE,
        urls: {
          apiURL: "https://explorer.redstone.xyz/api",
          browserURL: "https://explorer.redstone.xyz",
        },
      },
      {
        network: "blast",
        chainId: CHAIN_IDs.BLAST,
        urls: {
          apiURL: "https://api.blastscan.io/api",
          browserURL: "https://blastscan.io",
        },
      },
      {
        network: "blast-sepolia",
        chainId: CHAIN_IDs.BLAST_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.blastscan.io/api",
          browserURL: "https://sepolia.blastscan.io",
        },
      },
      {
        network: "worldchain",
        chainId: CHAIN_IDs.WORLD_CHAIN,
        urls: {
          apiURL: "https://worldchain-mainnet.explorer.alchemy.com/api",
          browserURL: "https://worldchain-mainnet.explorer.alchemy.com",
        },
      },
      {
        network: "zora",
        chainId: CHAIN_IDs.ZORA,
        urls: {
          apiURL: "https://api.routescan.io/v2/network/mainnet/evm/7777777/etherscan",
          browserURL: "https://zorascan.xyz",
        },
      },
    ],
  },
  namedAccounts: { deployer: 0 },
  typechain: {
    outDir: "./typechain",
    target: "ethers-v5",
  },
  paths: {
    tests: "./test/evm/hardhat",
  },
};

export default config;
