import { ethers } from "../utils/utils";
import { getProvider, getSigner } from "./utils";
import { readFileSync } from "fs";
import path from "path";
import { CID } from "multiformats/cid";
import PinataSDK from "@pinata/sdk";

const mintableERC1155Abi = ["function setTokenURI(uint256 tokenId, string memory uri) external"];

/**
 * Script to upload metadata JSON file to IPFS via Pinata and set token uri. Make sure to set the env var
 * `PINATA_JWT` in your .env file. Then you can run this script with:
 * ```
 * TOKEN_ID=<TOKEN_ID> \
 * METADATA=<PATH> \
 * ERC1155_ADDRESS=<ADDRESS> \
 * NODE_URL=<rpc> \
 * MNEMONIC="..." \
 * npx ts-node ./scripts/setERC1155Metadata.ts
 * ```
 */
async function main() {
  const tokenId = parseInt(process.env.TOKEN_ID || "0");
  const metadata = parseAndValidateMetadata();
  console.log(`Setting ERC1155 metadata for:`, { tokenId, metadata });

  const pinata = new PinataSDK({ pinataJWTKey: process.env.PINATA_JWT });
  const pinResult = await pinata.pinJSONToIPFS(metadata, { pinataMetadata: { name: `${tokenId}-metadata.json` } });
  const metadataIpfsLink = `ipfs://${pinResult.IpfsHash}`;
  console.log(`Successfully uploaded metadata to IPFS:`, metadataIpfsLink);

  const provider = getProvider();
  const signer = getSigner(provider);
  const erc1155Address = process.env.ERC1155_ADDRESS;
  if (!erc1155Address) throw new Error("ERC1155_ADDRESS env var required");
  const erc1155 = new ethers.Contract(erc1155Address, mintableERC1155Abi, signer);
  const setTokenUriTx = await erc1155.setTokenURI(tokenId, metadataIpfsLink);
  console.log(`Setting token uri...`);
  console.log("Tx hash:", setTokenUriTx.hash);
  await setTokenUriTx.wait();
  console.log(`Successfully set token uri`);
}

function parseAndValidateMetadata() {
  if (!process.env.METADATA) {
    throw new Error("Missing path to a JSON file with token metadata. Pass it via env var METADATA=<PATH>");
  }
  const metadataFilePath = path.join(__dirname, "..", process.env.METADATA);
  const metadataFromFile: Record<string, string> = JSON.parse(readFileSync(metadataFilePath, "utf8"));
  const requiredKeys = ["name", "description", "image", "animation_url"];

  if (!requiredKeys.every((k) => k in metadataFromFile)) {
    throw new Error(`Invalid metadata: required keys ${requiredKeys}`);
  }

  requireIpfsLink(metadataFromFile.image, "image");
  requireIpfsLink(metadataFromFile.animation_url, "animation_url");

  return metadataFromFile;
}

function requireIpfsLink(ipfsLink: string, key: string) {
  if (!ipfsLink.startsWith("ipfs://")) {
    throw new Error(`Invalid metadata: '${key}' must be an IPFS link ipfs://<CID>`);
  }
  const cid = ipfsLink.split("ipfs://")[1];
  CID.parse(cid); // throws if invalid
}

main().then(
  () => console.log("Done"),
  (error) => {
    console.log(error);
    process.exitCode = 1;
  }
);
