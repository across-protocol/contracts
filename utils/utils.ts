import fs from "fs";
import path from "path";
import { defaultAbiCoder } from "@ethersproject/abi";
import { BigNumber } from "@ethersproject/bignumber";
import { hexlify, isHexString } from "@ethersproject/bytes";
import { keccak256 } from "@ethersproject/keccak256";

export function findArtifactFromPath(contractName: string, artifactsPath: string) {
  const allArtifactsPaths = getAllFilesInPath(artifactsPath);
  const desiredArtifactPaths = allArtifactsPaths.filter((a) => a.endsWith(`/${contractName}.json`));

  if (desiredArtifactPaths.length !== 1)
    throw new Error(`Couldn't find desired artifact or found too many for ${contractName}`);
  return JSON.parse(fs.readFileSync(desiredArtifactPaths[0], "utf-8"));
}

export function getAllFilesInPath(dirPath: string, arrayOfFiles: string[] = []): string[] {
  const files = fs.readdirSync(dirPath);

  files.forEach((file) => {
    if (fs.statSync(dirPath + "/" + file).isDirectory())
      arrayOfFiles = getAllFilesInPath(dirPath + "/" + file, arrayOfFiles);
    else arrayOfFiles.push(path.join(dirPath, "/", file));
  });

  return arrayOfFiles;
}

export const toBN = (num: string | number | BigNumber) => {
  // If the string version of the num contains a `.` then it is a number which needs to be parsed to a string int.
  if (num.toString().includes(".")) return BigNumber.from(parseInt(num.toString()));
  return BigNumber.from(num.toString());
};

export function hashNonEmptyMessage(message: string) {
  if (!isHexString(message) || message.length % 2 !== 0) throw new Error("Invalid hex message bytes");

  // account for 0x prefix when checking length
  if (message.length > 2) {
    return keccak256(message);
  }
  return hexlify(new Uint8Array(32));
}

export { defaultAbiCoder, keccak256 };
