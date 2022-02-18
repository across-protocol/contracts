import * as dotenv from "dotenv";

import { HardhatUserConfig } from "hardhat/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-deploy";

dotenv.config();

console.log("process.env.CUSTOM_NODE_URL", process.env.CUSTOM_NODE_URL);

const config: HardhatUserConfig = {
  solidity: { compilers: [{ version: "0.8.11", settings: { optimizer: { enabled: true, runs: 200 } } }] },
  networks: {
    hardhat: { accounts: { accountsBalance: "1000000000000000000000000" } },
    kovan: {
      url: process.env.CUSTOM_NODE_URL,
      accounts: { mnemonic: process.env.MNEMONIC },
      saveDeployments: true,
      chainId: 42,
    },
  },
  gasReporter: { enabled: process.env.REPORT_GAS !== undefined, currency: "USD" },
  etherscan: { apiKey: process.env.ETHERSCAN_API_KEY },
  namedAccounts: { deployer: 0 },
};

export default config;
