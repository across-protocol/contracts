/**
 * Script to airdrop ERC1155 tokens to a list of recipients. The list of recipients need to be passed via a JSON file.
 * ```
 * RECIPIENTS=<PATH> yarn hardhat run ./scripts/mintERC1155.ts --network polygon-mumbai
 * ```
 */

import { getContractFactory, ethers, hre } from "../test/utils";
import { readFileSync } from "fs";
import path from "path";

const TOKEN_ID = 0;
const RECIPIENTS_CHUNK_SIZE = 100; // TODO: Still need to figure out which size is optimal

async function main() {
  const validRecipients = parseAndValidateRecipients();

  const [signer] = await ethers.getSigners();

  const erc1155Deployment = await hre.deployments.get("MintableERC1155");
  const erc1155 = (await getContractFactory("MintableERC1155", { signer })).attach(erc1155Deployment.address);

  for (let i = 0; i < validRecipients.length; i = i + RECIPIENTS_CHUNK_SIZE) {
    const recipientsChunk = validRecipients.slice(i, i + RECIPIENTS_CHUNK_SIZE);
    const airdropTx = await erc1155.airdrop(TOKEN_ID, recipientsChunk, 1);
    console.log(
      `Minting token with id ${TOKEN_ID} to ${recipientsChunk.length} recipients in index range ${i} - ${
        i + RECIPIENTS_CHUNK_SIZE - 1
      }: `,
      airdropTx.hash
    );
    await airdropTx.wait();
    console.log(`Successfully minted token to:`, recipientsChunk);
  }
}

function parseAndValidateRecipients() {
  if (!process.env.RECIPIENTS) {
    throw new Error("Missing path to a JSON file with the list of recipients. Pass it via env var RECIPIENTS=<PATH>");
  }
  const recipientsFilePath = path.join(__dirname, "..", process.env.RECIPIENTS);
  const recipientsFromFile: string[] = JSON.parse(readFileSync(recipientsFilePath, "utf8"));
  const invalidRecipients = recipientsFromFile.filter((r) => !ethers.utils.isAddress(r));

  if (invalidRecipients.length > 0) {
    throw new Error(`Invalid recipients: ${invalidRecipients}`);
  }

  if (new Set(recipientsFromFile).size !== recipientsFromFile.length) {
    throw new Error("Recipients list contains duplicates");
  }

  return recipientsFromFile.map((r) => ethers.utils.getAddress(r));
}

main().then(
  () => console.log("Done"),
  (error) => {
    console.log(error);
    process.exitCode = 1;
  }
);
