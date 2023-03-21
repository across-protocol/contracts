import { getContractFactory, ethers, hre } from "../test/utils";
import { readFileSync } from "fs";
import path from "path";
import { getNodeUrl } from "@uma/common";

const RECIPIENTS_CHUNK_SIZE = 100; // TODO: Still need to figure out which size is optimal

/**
 * Script to airdrop ERC1155 tokens to a list of recipients. The list of recipients need to be passed via a JSON file.
 * ```
 * TOKEN_ID=<TOKEN_ID> \
 * RECIPIENTS=<PATH> \
 * yarn hardhat run ./scripts/mintERC1155.ts --network polygon-mumbai
 * ```
 */
async function main() {
  const tokenId = parseInt(process.env.TOKEN_ID || "0");
  const validRecipients = await parseAndValidateRecipients();

  const [signer] = await ethers.getSigners();

  const erc1155Deployment = await hre.deployments.get("MintableERC1155");
  const erc1155 = (await getContractFactory("MintableERC1155", { signer })).attach(erc1155Deployment.address);

  for (let i = 0; i < validRecipients.length; i = i + RECIPIENTS_CHUNK_SIZE) {
    const recipientsChunk = validRecipients.slice(i, i + RECIPIENTS_CHUNK_SIZE);
    const airdropTx = await erc1155.airdrop(tokenId, recipientsChunk, 1);
    console.log(
      `Minting token with id ${tokenId} to ${recipientsChunk.length} recipients in index range ${i} - ${
        i + RECIPIENTS_CHUNK_SIZE - 1
      }...`
    );
    console.log("Tx hash:", airdropTx.hash);
    await airdropTx.wait();
    console.log(`Successfully minted token to chunk:`, {
      first: recipientsChunk[0],
      last: recipientsChunk[recipientsChunk.length - 1],
    });
  }
}

async function parseAndValidateRecipients() {
  const provider = new ethers.providers.JsonRpcProvider(getNodeUrl("mainnet", true, 1));

  if (!process.env.RECIPIENTS) {
    throw new Error("Missing path to a JSON file with the list of recipients. Pass it via env var RECIPIENTS=<PATH>");
  }
  const recipientsFilePath = path.join(__dirname, "..", process.env.RECIPIENTS);
  const recipientsFromFile: string[] = JSON.parse(readFileSync(recipientsFilePath, "utf8"));

  const resolvedRecipients = await Promise.all(
    recipientsFromFile.map(async (r) => {
      if (r.toLocaleLowerCase().endsWith(".eth")) {
        const resolvedAddress = await provider.resolveName(r);
        if (!resolvedAddress) {
          throw new Error(`Could not resolve ENS name: ${r}`);
        }
        return resolvedAddress;
      }
      return Promise.resolve(r);
    })
  );

  const invalidRecipients = resolvedRecipients.filter((r) => !ethers.utils.isAddress(r));

  if (invalidRecipients.length > 0) {
    throw new Error(`Invalid recipients: ${invalidRecipients}`);
  }

  if (new Set(resolvedRecipients).size !== resolvedRecipients.length) {
    throw new Error("Recipients list contains duplicates");
  }

  return resolvedRecipients.map((r) => ethers.utils.getAddress(r));
}

main().then(
  () => console.log("Done"),
  (error) => {
    console.log(error);
    process.exitCode = 1;
  }
);
