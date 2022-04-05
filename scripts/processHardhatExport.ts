import fs from "fs";
import path from "path";

import * as deploymentExport from "../cache/massExport.json";

// Prunes the hardhat export file sent to the cache directory to only contain the deployment addresses of each contract
// over the network of chains the Across v2 contracts are deployed on. Meant to be run as part of a publish process.
export async function run(): Promise<void> {
  const castExport = deploymentExport as any;
  console.log("Generating exports on the following networks(if they have deployments)", Object.keys(castExport));
  const processedOutput: { [chainid: string]: { [contractName: string]: string } } = {};
  Object.keys(castExport).forEach((chainId) => {
    if (castExport[chainId][0])
      Object.keys(castExport[chainId][0].contracts).forEach((contractName) => {
        if (!processedOutput[chainId]) processedOutput[chainId] = {};
        processedOutput[chainId][contractName] = castExport[chainId][0]?.contracts[contractName].address;
      });
  });
  console.log("Constructed the following address export for release:\n", processedOutput);

  fs.writeFileSync(`${path.resolve(__dirname)}/../deployments/deployments.json`, JSON.stringify(processedOutput));
}

if (require.main === module) {
  run().then(() => {
    process.exit(0);
  });
}
