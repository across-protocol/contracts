import "hardhat/types/runtime";
import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import { DeploymentsExtension } from "hardhat-deploy/dist/types";
import { HardhatNetworkConfig, HttpNetworkConfig } from "hardhat/types";

declare module "hardhat/types" {
  interface HardhatNetworkConfig {
    url?: string;
  }

  interface HttpNetworkConfig {
    url: string;
  }
}

declare module "hardhat/types/runtime" {
  interface HardhatRuntimeEnvironment {
    deployments: DeploymentsExtension;
    getChainId: () => Promise<string>;
  }
}
