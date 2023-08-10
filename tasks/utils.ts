import { ethers } from "ethers";
import readline from "readline";
export const zeroAddress = ethers.constants.AddressZero;

export const minimalSpokePoolInterface = [
  {
    inputs: [
      { internalType: "address", name: "l2Token", type: "address" },
      { internalType: "address", name: "l1Token", type: "address" },
    ],
    name: "whitelistToken",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "address", name: "l2Token", type: "address" },
      { internalType: "address", name: "tokenBridge", type: "address" },
    ],
    name: "setTokenBridge",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
];

async function askQuestion(query: string) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  return new Promise((resolve) =>
    rl.question(query, (ans) => {
      rl.close();
      resolve(ans);
    })
  );
}

export async function askYesNoQuestion(query: string): Promise<boolean> {
  const ans = (await askQuestion(`${query} (y/n) `)) as string;
  if (ans.toLowerCase() === "y") return true;
  if (ans.toLowerCase() === "n") return false;
  return askYesNoQuestion(query);
}
