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
  {
    inputs: [
      {
        internalType: "uint32",
        name: "rootBundleId",
        type: "uint32",
      },
      {
        components: [
          {
            internalType: "uint256",
            name: "amountToReturn",
            type: "uint256",
          },
          {
            internalType: "uint256",
            name: "chainId",
            type: "uint256",
          },
          {
            internalType: "uint256[]",
            name: "refundAmounts",
            type: "uint256[]",
          },
          {
            internalType: "uint32",
            name: "leafId",
            type: "uint32",
          },
          {
            internalType: "address",
            name: "l2TokenAddress",
            type: "address",
          },
          {
            internalType: "address[]",
            name: "refundAddresses",
            type: "address[]",
          },
        ],
        internalType: "struct SpokePoolInterface.RelayerRefundLeaf",
        name: "relayerRefundLeaf",
        type: "tuple",
      },
      {
        internalType: "bytes32[]",
        name: "proof",
        type: "bytes32[]",
      },
    ],
    name: "executeRelayerRefundLeaf",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "relayerRefundRoot",
        type: "bytes32",
      },
      {
        internalType: "bytes32",
        name: "slowRelayRoot",
        type: "bytes32",
      },
    ],
    name: "relayRootBundle",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    name: "rootBundles",
    outputs: [
      {
        internalType: "bytes32",
        name: "slowRelayRoot",
        type: "bytes32",
      },
      {
        internalType: "bytes32",
        name: "relayerRefundRoot",
        type: "bytes32",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

export const minimalAdapterInterface = [
  {
    inputs: [
      {
        internalType: "address",
        name: "target",
        type: "address",
      },
      {
        internalType: "bytes",
        name: "message",
        type: "bytes",
      },
    ],
    name: "relayMessage",
    outputs: [],
    stateMutability: "payable",
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
