import fs from "fs";
import path from "path";

async function main() {
  if (!process.env.CONTRACT_NAME) {
    console.log("Usage: CONTRACT_NAME=<CONTRACT_NAME> yarn hardhat run scripts/byteCodeCalculator.ts");
    return;
  }
  const contractName = process.env.CONTRACT_NAME;
  const artifactsPath = path.join(__dirname, `../artifacts/contracts/${contractName}.sol/${contractName}.json`);

  if (!fs.existsSync(artifactsPath)) {
    console.log(`No artifacts found for ${contractName}`);
    return;
  }

  const artifact = JSON.parse(fs.readFileSync(artifactsPath, "utf8"));
  // We have a bytecode string, which is 2 characters per byte + 0x prefix
  // We should halve this to get the number of bytes and subtract 1 for the 0x prefix
  const bytecodeSize = artifact.deployedBytecode.length / 2 - 1;

  console.log(`Bytecode size of ${contractName}: ${(bytecodeSize / 1024).toFixed(2)}KB (${bytecodeSize} bytes)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
