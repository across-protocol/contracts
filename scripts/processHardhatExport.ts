var fs = require("fs");
const path = require("path");

import * as deploymentExport from "../cache/massExport.json";
export async function run(): Promise<void> {
  console.log("Generating exports on the following networks(if they have deployments)", Object.keys(deploymentExport));
  const processedOutput: { [chainid: string]: { [contractName: string]: string } } = {};
  Object.keys(deploymentExport).forEach((chainId) => {
    if (deploymentExport[chainId][0])
      Object.keys(deploymentExport[chainId][0].contracts).forEach((contractName) => {
        if (!processedOutput[chainId]) processedOutput[chainId] = {};
        processedOutput[chainId][contractName] = deploymentExport[chainId][0]?.contracts[contractName].address;
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
