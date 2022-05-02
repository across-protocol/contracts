import fs from "fs";
import path from "path";

// Prunes the hardhat export file sent to the cache directory to only contain the deployment addresses of each contract
// over the network of chains the Across v2 contracts are deployed on. Meant to be run as part of a publish process.
export async function run(): Promise<void> {
  try {
    const deploymentExport = require("../cache/massExport.json");
    const castExport = deploymentExport as any;
    console.log("Generating exports on the following networks(if they have deployments)", Object.keys(castExport));
    const processedOutput: { [chainId: string]: { [name: string]: { address: string; blockNumber: number } } } = {};
    Object.keys(castExport).forEach((chainId) => {
      if (castExport[chainId][0])
        Object.keys(castExport[chainId][0].contracts).forEach((contractName) => {
          if (!processedOutput[chainId]) processedOutput[chainId] = {};
          const address = castExport[chainId][0]?.contracts[contractName].address;
          const blockNumber = findDeploymentBlockNumber(castExport[chainId][0].name, contractName);
          processedOutput[chainId][contractName] = { address, blockNumber };
        });
    });
    console.log("Constructed the following address export for release:\n", processedOutput);

    fs.writeFileSync(`${path.resolve(__dirname)}/../deployments/deployments.json`, JSON.stringify(processedOutput));
  } catch (error) {}
}

if (require.main === module) {
  run()
    .then(() => {
      process.exit(0);
    })
    .catch(async (error) => {
      console.error("Process exited with", error);
      process.exit(1);
    });
}

function findDeploymentBlockNumber(networkName: string, contractName: string) {
  const deploymentArtifact = require(`../deployments/${networkName}/${contractName}.json`);
  return (deploymentArtifact as any).receipt.blockNumber;
}
