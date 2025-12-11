const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } = require("hardhat/builtin-tasks/task-names");

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_: any, __: any, runSuper: any) => {
  const paths = await runSuper();

  // Filter out files that cause problems when using "paris" hardfork (currently used to compile everything when IS_TEST=true)
  // Reference: https://github.com/NomicFoundation/hardhat/issues/2306#issuecomment-1039452928
  if (process.env.IS_TEST === "true" || process.env.CI === "true") {
    return paths.filter((p: any) => {
      return (
        !p.includes("contracts/periphery/mintburn") &&
        !p.includes("contracts/external/libraries/BytesLib.sol") &&
        !p.includes("contracts/libraries/SponsoredCCTPQuoteLib.sol") &&
        !p.includes("contracts/external/libraries/MinimalLZOptions.sol")
      );
    });
  }

  return paths;
});

import * as dotenv from "dotenv";
dotenv.config();
import { HardhatUserConfig } from "hardhat/config";
import { CHAIN_IDs } from "./utils/constants";
import { getNodeUrl } from "./utils";

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

const getMnemonic = () => {
  // Publicly-disclosed mnemonic. This is required for hre deployments in test.
  const PUBLIC_MNEMONIC = "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat";
  const { MNEMONIC = PUBLIC_MNEMONIC } = process.env;
  return MNEMONIC;
};
const mnemonic = getMnemonic();

const getDefaultHardhatConfig = (chainId: number, isTestnet: boolean = false): any => {
  return {
    chainId,
    url: getNodeUrl(chainId),
    accounts: { mnemonic },
    saveDeployments: true,
    companionNetworks: { l1: isTestnet ? "sepolia" : "mainnet" },
  };
};

// Custom tasks to add to HRE.
const tasks = [
  "enableL1TokenAcrossEcosystem",
  "finalizeScrollClaims",
  "rescueStuckScrollTxn",
  "verifySpokePool",
  "verifyBytecode",
  "evmRelayMessageWithdrawal",
  "testChainAdapter",
  "upgradeSpokePool",
];

// eslint-disable-next-line node/no-missing-require
tasks.forEach((task) => require(`./tasks/${task}`));

const isTest = process.env.IS_TEST === "true" || process.env.CI === "true";

// To compile with zksolc, `hardhat` must be the default network and its `zksync` property must be true.
// So we allow the caller to set this environment variable to toggle compiling zk contracts or not.
// TODO: Figure out way to only compile specific contracts intended to be deployed on ZkSync (e.g. ZkSync_SpokePool) if
// the following config is true.
const compileZk = process.env.COMPILE_ZK === "true";

const solcVersion = "0.8.30";

// Hardhat 2.14.0 doesn't support prague yet, so we use paris instead (need to upgrade to v3 to use prague)
const evmVersion = isTest ? "paris" : "prague";

// Compilation settings are overridden for large contracts to allow them to compile without going over the bytecode
// limit.
const LARGE_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 800 },
    viaIR: true,
    evmVersion,
    debug: { revertStrings: isTest ? "debug" : "strip" },
  },
};
const DEFAULT_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 1000000 },
    viaIR: true,
    evmVersion,
    // Only strip revert strings if not testing or in ci.
    debug: { revertStrings: isTest ? "debug" : "strip" },
  },
};
// This is only used by Blast_SpokePool for now, as it's the largest bytecode-wise
const LARGEST_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 50 },
    viaIR: true,
    evmVersion,
    debug: { revertStrings: isTest ? "debug" : "strip" },
  },
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [DEFAULT_CONTRACT_COMPILER_SETTINGS],
    overrides: {
      "contracts/HubPool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Linea_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Universal_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Arbitrum_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Scroll_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Lisk_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/OP_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Optimism_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/WorldChain_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Ink_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Cher_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Blast_SpokePool.sol": LARGEST_CONTRACT_COMPILER_SETTINGS,
      "contracts/Tatara_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/periphery/mintburn/HyperCoreFlowExecutor.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
    },
  },
  zksolc: {
    version: "1.5.7",
    settings: {
      optimizer: {
        enabled: true,
      },
      suppressedErrors: ["sendtransfer"],
      contractsToCompile: [
        "SpokePoolPeriphery",
        "MulticallHandler",
        "SpokePoolVerifier",
        "ZkSync_SpokePool",
        "Lens_SpokePool",
        "AcrossEventEmitter",
      ],
    },
  },
  networks: {
    hardhat: {
      accounts: { accountsBalance: "1000000000000000000000000" },
      zksync: compileZk,
      allowUnlimitedContractSize: true,
    },
    mainnet: getDefaultHardhatConfig(CHAIN_IDs.MAINNET),
    zksync: {
      chainId: CHAIN_IDs.ZK_SYNC,
      url: getNodeUrl(CHAIN_IDs.ZK_SYNC),
      saveDeployments: true,
      accounts: { mnemonic },
      ethNetwork: "mainnet",
      companionNetworks: { l1: "mainnet" },
      zksync: true,
      verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
    },
    optimism: getDefaultHardhatConfig(CHAIN_IDs.OPTIMISM),
    "optimism-sepolia": getDefaultHardhatConfig(CHAIN_IDs.OPTIMISM_SEPOLIA, true),
    arbitrum: getDefaultHardhatConfig(CHAIN_IDs.ARBITRUM),
    "arbitrum-sepolia": getDefaultHardhatConfig(CHAIN_IDs.ARBITRUM_SEPOLIA, true),
    sepolia: getDefaultHardhatConfig(CHAIN_IDs.SEPOLIA, true),
    polygon: getDefaultHardhatConfig(CHAIN_IDs.POLYGON),
    bsc: {
      ...getDefaultHardhatConfig(CHAIN_IDs.BSC),
      gas: "auto",
      gasPrice: 3e8, // 0.3 GWEI
      gasMultiplier: 4.0,
    },
    hyperevm: getDefaultHardhatConfig(CHAIN_IDs.HYPEREVM),
    "hyperevm-testnet": getDefaultHardhatConfig(CHAIN_IDs.HYPEREVM_TESTNET, true),
    monad: getDefaultHardhatConfig(CHAIN_IDs.MONAD),
    "polygon-amoy": getDefaultHardhatConfig(CHAIN_IDs.POLYGON_AMOY),
    base: getDefaultHardhatConfig(CHAIN_IDs.BASE),
    "base-sepolia": getDefaultHardhatConfig(CHAIN_IDs.BASE_SEPOLIA, true),
    ink: getDefaultHardhatConfig(CHAIN_IDs.INK),
    linea: getDefaultHardhatConfig(CHAIN_IDs.LINEA),
    plasma: getDefaultHardhatConfig(CHAIN_IDs.PLASMA),
    scroll: getDefaultHardhatConfig(CHAIN_IDs.SCROLL),
    "scroll-sepolia": getDefaultHardhatConfig(CHAIN_IDs.SCROLL_SEPOLIA, true),
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
    mode: getDefaultHardhatConfig(CHAIN_IDs.MODE),
    "mode-sepolia": getDefaultHardhatConfig(CHAIN_IDs.MODE_SEPOLIA, true),
    tatara: {
      chainId: CHAIN_IDs.TATARA,
      url: getNodeUrl(CHAIN_IDs.TATARA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
      ethNetwork: "sepolia",
    },
    lens: {
      chainId: CHAIN_IDs.LENS,
      url: getNodeUrl(CHAIN_IDs.LENS),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "mainnet" },
      ethNetwork: "mainnet",
      verifyURL: "https://verify.lens.xyz/contract_verification",
      zksync: true,
    },
    "lens-sepolia": {
      chainId: CHAIN_IDs.LENS_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.LENS_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
      ethNetwork: "sepolia",
      verifyURL: "https://block-explorer-verify.testnet.lens.dev/contract_verification",
      zksync: true,
    },
    lisk: getDefaultHardhatConfig(CHAIN_IDs.LISK),
    "lisk-sepolia": getDefaultHardhatConfig(CHAIN_IDs.LISK_SEPOLIA, true),
    redstone: getDefaultHardhatConfig(CHAIN_IDs.REDSTONE),
    blast: getDefaultHardhatConfig(CHAIN_IDs.BLAST),
    "blast-sepolia": getDefaultHardhatConfig(CHAIN_IDs.BLAST_SEPOLIA, true),
    worldchain: getDefaultHardhatConfig(CHAIN_IDs.WORLD_CHAIN),
    zora: getDefaultHardhatConfig(CHAIN_IDs.ZORA),
    soneium: getDefaultHardhatConfig(CHAIN_IDs.SONEIUM),
    unichain: getDefaultHardhatConfig(CHAIN_IDs.UNICHAIN),
    "unichain-sepolia": getDefaultHardhatConfig(CHAIN_IDs.UNICHAIN_SEPOLIA, true),
    "bob-sepolia": getDefaultHardhatConfig(CHAIN_IDs.BOB_SEPOLIA, true),
  },
  gasReporter: { enabled: process.env.REPORT_GAS !== undefined, currency: "USD" },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY!,
    customChains: [
      {
        network: "blast",
        chainId: CHAIN_IDs.BLAST,
        urls: {
          apiURL: "https://blastscan.io/api",
          browserURL: "https://blastscan.io",
        },
      },
      {
        network: "hyperevm",
        chainId: CHAIN_IDs.HYPEREVM,
        urls: {
          apiURL: "https://hyperevmscan.io/api",
          browserURL: "https://hyperevmscan.io",
        },
      },
      {
        network: "linea",
        chainId: CHAIN_IDs.LINEA,
        urls: {
          apiURL: "https://lineascan.build/api",
          browserURL: "https://lineascan.build",
        },
      },
      {
        network: "scroll",
        chainId: CHAIN_IDs.SCROLL,
        urls: {
          apiURL: "https://api.scrollscan.com/api",
          browserURL: "https://scrollscan.com",
        },
      },
      {
        network: "unichain",
        chainId: CHAIN_IDs.UNICHAIN,
        urls: {
          apiURL: "https://api.uniscan.xyz/api",
          browserURL: "https://uniscan.xyz",
        },
      },
      {
        network: "zksync",
        chainId: CHAIN_IDs.ZK_SYNC,
        urls: {
          apiURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
          browserURL: "https://era.zksync.network/",
        },
      },
      {
        network: "lens",
        chainId: CHAIN_IDs.LENS,
        urls: {
          apiURL: "https://verify.lens.xyz/contract_verification",
          browserURL: "https://explorer.lens.xyz/",
        },
      },
    ],
  },
  blockscout: {
    enabled: true,
    customChains: [
      {
        network: "bob-sepolia",
        chainId: CHAIN_IDs.BOB_SEPOLIA,
        urls: {
          apiURL: "https://bob-sepolia.explorer.gobob.xyz/api",
          browserURL: "https://bob-sepolia.explorer.gobob.xyz",
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
        network: "mode",
        chainId: CHAIN_IDs.MODE,
        urls: {
          apiURL: "https://explorer.mode.network/api",
          browserURL: "https://explorer.mode.network/",
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
        network: "redstone",
        chainId: CHAIN_IDs.REDSTONE,
        urls: {
          apiURL: "https://explorer.redstone.xyz/api",
          browserURL: "https://explorer.redstone.xyz",
        },
      },
      {
        network: "plasma",
        chainId: 9745,
        urls: {
          apiURL: "https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan",
          browserURL: "https://plasmascan.to",
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
        network: "tatara",
        chainId: CHAIN_IDs.TATARA,
        urls: {
          apiURL: "https://explorer.tatara.katana.network/api",
          browserURL: "https://explorer.tatara.katana.network",
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
