import { evmAddressToPublicKey } from "../../src/svm";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
const argv = yargs(hideBin(process.argv)).option("address", {
  type: "string",
  demandOption: true,
  describe: "Ethereum address to convert",
}).argv;

async function logPublicKey(): Promise<void> {
  const address = (await argv).address;

  const publicKey = evmAddressToPublicKey(address);

  console.log("Ethereum Address:", address);
  console.log("Associated Public Key:", publicKey.toString());
}
logPublicKey();
