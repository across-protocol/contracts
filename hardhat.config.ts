import * as dotenv from "dotenv";
dotenv.config();
import { HardhatUserConfig } from "hardhat/config";
import { CHAIN_IDs, PUBLIC_NETWORKS } from "./utils/constants";

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

const getNodeUrl = (chainId: number): string => {
  let url = process.env[`NODE_URL_${chainId}`] ?? process.env.CUSTOM_NODE_URL;
  if (url === undefined) {
    // eslint-disable-next-line no-console
    console.log(`No configured RPC provider for chain ${chainId}, reverting to public RPC.`);
    url = PUBLIC_NETWORKS[chainId].publicRPC;
  }

  return url;
};

const getMnemonic = () => {
  // Publicly-disclosed mnemonic. This is required for hre deployments in test.
  const PUBLIC_MNEMONIC = "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat";
  const { MNEMONIC = PUBLIC_MNEMONIC } = process.env;
  return MNEMONIC;
};
const mnemonic = getMnemonic();

const getDefaultHardhatConfig = (chainId: number): any => {
  return {
    chainId,
    url: getNodeUrl(chainId),
    accounts: { mnemonic },
    saveDeployments: true,
    companionNetworks: { l1: "mainnet" },
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

const solcVersion = "0.8.23";

// Compilation settings are overridden for large contracts to allow them to compile without going over the bytecode
// limit.
const LARGE_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 800 },
    viaIR: true,
    debug: { revertStrings: isTest ? "debug" : "strip" },
  },
};
const DEFAULT_CONTRACT_COMPILER_SETTINGS = {
  version: solcVersion,
  settings: {
    optimizer: { enabled: true, runs: 1000000 },
    viaIR: true,
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
    debug: { revertStrings: isTest ? "debug" : "strip" },
  },
};

const config: HardhatUserConfig = {
  solidity: {
    compilers: [DEFAULT_CONTRACT_COMPILER_SETTINGS],
    overrides: {
      "contracts/HubPool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Linea_SpokePool.sol": {
        ...LARGE_CONTRACT_COMPILER_SETTINGS,
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
      "contracts/Universal_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Arbitrum_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Scroll_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Lisk_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Redstone_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Zora_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Mode_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Base_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Optimism_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/WorldChain_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Ink_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Cher_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/DoctorWho_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Blast_SpokePool.sol": LARGEST_CONTRACT_COMPILER_SETTINGS,
      "contracts/Tatara_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
      "contracts/Bob_SpokePool.sol": LARGE_CONTRACT_COMPILER_SETTINGS,
    },
  },
  zksolc: {
    version: "1.5.7",
    settings: {
      optimizer: {
        enabled: true,
      },
      suppressedErrors: ["sendtransfer"],
      contractsToCompile: ["SpokePoolPeriphery", "MulticallHandler"],
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
    "optimism-sepolia": {
      chainId: CHAIN_IDs.OPTIMISM_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.OPTIMISM_SEPOLIA),
      accounts: { mnemonic },
      saveDeployments: true,
      companionNetworks: { l1: "sepolia" },
    },
    arbitrum: getDefaultHardhatConfig(CHAIN_IDs.ARBITRUM),
    "arbitrum-sepolia": {
      chainId: CHAIN_IDs.ARBITRUM_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.ARBITRUM_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    sepolia: {
      chainId: CHAIN_IDs.SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.SEPOLIA),
      accounts: { mnemonic },
      saveDeployments: true,
      companionNetworks: { l1: "sepolia" },
    },
    polygon: getDefaultHardhatConfig(CHAIN_IDs.POLYGON),
    bsc: getDefaultHardhatConfig(CHAIN_IDs.BSC),
    // ! Notice. Params below helped deploy Universal_Spoke on BSC, but might not be desirable always
    // gas: "auto",
    // gasPrice: 3e8, // 0.3 GWEI
    // gasMultiplier: 4.0,
    hyperevm: getDefaultHardhatConfig(CHAIN_IDs.HYPEREVM),
    "polygon-amoy": {
      chainId: CHAIN_IDs.POLYGON_AMOY,
      url: getNodeUrl(CHAIN_IDs.POLYGON_AMOY),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    base: getDefaultHardhatConfig(CHAIN_IDs.BASE),
    "base-sepolia": {
      chainId: CHAIN_IDs.BASE_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.BASE_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    ink: getDefaultHardhatConfig(CHAIN_IDs.INK),
    linea: getDefaultHardhatConfig(CHAIN_IDs.LINEA),
    plasma: getDefaultHardhatConfig(CHAIN_IDs.PLASMA),
    scroll: getDefaultHardhatConfig(CHAIN_IDs.SCROLL),
    "scroll-sepolia": {
      chainId: CHAIN_IDs.SCROLL_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.SCROLL_SEPOLIA),
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
    mode: getDefaultHardhatConfig(CHAIN_IDs.MODE),
    "mode-sepolia": {
      chainId: CHAIN_IDs.MODE_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.MODE_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
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
    "lisk-sepolia": {
      chainId: CHAIN_IDs.LISK_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.LISK_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    redstone: getDefaultHardhatConfig(CHAIN_IDs.REDSTONE),
    blast: getDefaultHardhatConfig(CHAIN_IDs.BLAST),
    "blast-sepolia": {
      chainId: CHAIN_IDs.BLAST_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.BLAST_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    worldchain: getDefaultHardhatConfig(CHAIN_IDs.WORLD_CHAIN),
    zora: getDefaultHardhatConfig(CHAIN_IDs.ZORA),
    soneium: getDefaultHardhatConfig(CHAIN_IDs.SONEIUM),
    unichain: getDefaultHardhatConfig(CHAIN_IDs.UNICHAIN),
    "unichain-sepolia": {
      chainId: CHAIN_IDs.UNICHAIN_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.UNICHAIN_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
    },
    "bob-sepolia": {
      chainId: CHAIN_IDs.BOB_SEPOLIA,
      url: getNodeUrl(CHAIN_IDs.BOB_SEPOLIA),
      saveDeployments: true,
      accounts: { mnemonic },
      companionNetworks: { l1: "sepolia" },
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
      bsc: process.env.BNB_ETHERSCAN_API_KEY!,
      hyperevm: process.env.ETHERSCAN_API_KEY!,
      mode: "blockscout",
      "mode-sepolia": "blockscout",
      tatara: "blockscout",
      lisk: "blockscout",
      "lisk-sepolia": "blockscout",
      redstone: "blockscout",
      blast: process.env.BLAST_ETHERSCAN_API_KEY!,
      "blast-sepolia": process.env.BLAST_ETHERSCAN_API_KEY!,
      zora: "routescan",
      worldchain: "blockscout",
      ink: "blockscout",
      soneium: "blockscout",
      unichain: process.env.UNICHAIN_ETHERSCAN_API_KEY!,
      "unichain-sepolia": process.env.UNICHAIN_ETHERSCAN_API_KEY!,
      "bob-sepolia": "blockscout",
    },
    customChains: [
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
          browserURL: "https://lineascan.build",
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
          browserURL: "https://scrollscan.com",
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
        network: "tatara",
        chainId: CHAIN_IDs.TATARA,
        urls: {
          apiURL: "https://explorer.tatara.katana.network/api",
          browserURL: "https://explorer.tatara.katana.network",
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
      {
        network: "unichain",
        chainId: CHAIN_IDs.UNICHAIN,
        urls: {
          apiURL: "https://api.uniscan.xyz/api",
          browserURL: "https://uniscan.xyz",
        },
      },
      {
        network: "unichain-sepolia",
        chainId: CHAIN_IDs.UNICHAIN_SEPOLIA,
        urls: {
          apiURL: "https://api-sepolia.uniscan.xyz/api",
          browserURL: "https://sepolia.uniscan.xyz",
        },
      },
      {
        network: "bob-sepolia",
        chainId: CHAIN_IDs.BOB_SEPOLIA,
        urls: {
          apiURL: "https://bob-sepolia.explorer.gobob.xyz/api",
          browserURL: "https://bob-sepolia.explorer.gobob.xyz",
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
