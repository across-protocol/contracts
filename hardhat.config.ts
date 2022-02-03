import * as dotenv from "dotenv";

import { HardhatUserConfig, task } from "hardhat/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-deploy";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: { compilers: [{ version: "0.8.11", settings: { optimizer: { enabled: true, runs: 200 } } }] },
  networks: {
    hardhat: {
      accounts: {
        accountsBalance: "1000000000000000000000000", // 1mil ETH
      },
    },
  },
  gasReporter: { enabled: process.env.REPORT_GAS !== undefined, currency: "USD" },
  etherscan: { apiKey: process.env.ETHERSCAN_API_KEY },
};

export default config;
