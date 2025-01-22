import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import { getMnemonic } from "@uma/common";
import { ChainFamily, CHAIN_IDs, PUBLIC_NETWORKS, MAINNET_CHAIN_IDs } from "./utils/constants";

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

const ZK_STACK_VERIFY_URLS: { [chainId: number]: string } = {
  [CHAIN_IDs.ZK_SYNC]: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
  [CHAIN_IDs.LENS_SEPOLIA]: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
  [CHAIN_IDs.ZK_SYNC_SEPOLIA]: "https://explorer.sepolia.era.zksync.dev/contract_verification",
};

const networks = Object.fromEntries(
  Object.values(CHAIN_IDs)
    .filter((chainId) => PUBLIC_NETWORKS[chainId] !== undefined)
    .map((chainId) => {
      const network = PUBLIC_NETWORKS[chainId];
      const hubChainId = Object.values(MAINNET_CHAIN_IDs).includes(chainId) ? CHAIN_IDs.MAINNET : CHAIN_IDs.SEPOLIA;
      const url =
        process.env[`NODE_URL_${chainId}`] ??
        network.publicRPC ??
        `error: no chain ${chainId} provider defined (set NODE_URL_${chainId})`;
      const chainDef = {
        url,
        accounts: { mnemonic },
        saveDeployments: true,
        chainId: hubChainId,
        companionNetworks: { l1: hubChainId === CHAIN_IDs.MAINNET ? "mainnet" : "sepolia" },
      };

      // zk stack chains are special snowflakes.
      // This block requires weird type mangling on `chainId` - why?
      if (PUBLIC_NETWORKS[chainId].family === ChainFamily.ZK_STACK) {
        const verifyURL = ZK_STACK_VERIFY_URLS[Number(chainId)];
        if (!verifyURL) {
          throw new Error(`No verifyURL defined for ZK stack chainId ${chainId}`);
        }

        (chainDef as Record<string, any>)["zksync"] = true;
        (chainDef as Record<string, any>)["verifyURL"] = verifyURL;
        (chainDef as Record<string, any>)["ethNetwork"] = chainDef.companionNetworks.l1;
      }

      return [chainId, chainDef];
    })
);

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
      "contracts/Ink_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Cher_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
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
    ...networks, // autogenerated
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
      ink: "blockscout",
      soneium: "blockscout",
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
        network: "ink",
        chainId: CHAIN_IDs.INK,
        urls: {
          apiURL: "https://explorer.inkonchain.com/api",
          browserURL: "https://explorer.inkonchain.com",
        },
      },
      {
        network: "soneium",
        chainId: CHAIN_IDs.SONEIUM,
        urls: {
          apiURL: "https://soneium.blockscout.com/api",
          browserURL: "https://soneium.blockscout.com",
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
