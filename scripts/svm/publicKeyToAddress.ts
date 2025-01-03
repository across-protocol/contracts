import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { publicKeyToEvmAddress } from "../../src/svm";

const argv = yargs(hideBin(process.argv)).option("publicKey", {
  type: "string",
  demandOption: true,
  describe: "Public key to convert",
}).argv;

async function logEvmAddress(): Promise<void> {
  const publicKey = (await argv).publicKey;
  const evmAddress = publicKeyToEvmAddress(publicKey);

  console.log("Public Key:", publicKey);
  console.log("Associated Ethereum Address:", evmAddress);
}

logEvmAddress();
