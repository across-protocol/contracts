import fetch from "node-fetch";
import { ethers } from "ethers";
import readline from "readline";
export const zeroAddress = ethers.constants.AddressZero;

export async function findL2TokenForL1Token(l2ChainId: number, l1TokenAddress: string) {
  if (l2ChainId == 10) {
    const foundOnChain = await _findL2TokenForOvmChain(l2ChainId, l1TokenAddress);
    if (foundOnChain != zeroAddress) return foundOnChain;
    else return await _findL2TokenFromTokenList(l2ChainId, l1TokenAddress);
  }
  if (l2ChainId == 137) return await _findL2TokenFromTokenList(l2ChainId, l1TokenAddress);
  if (l2ChainId == 288) return await _findL2TokenForOvmChain(l2ChainId, l1TokenAddress);
  if (l2ChainId == 42161) return await _findL2TokenFromTokenList(l2ChainId, l1TokenAddress);
}

async function _findL2TokenFromTokenList(l2ChainId: number, l1TokenAddress: string) {
  if (l2ChainId == 10) {
    const response = await fetch("https://static.optimism.io/optimism.tokenlist.json");
    const body = await response.text();
    const tokenList = JSON.parse(body).tokens;
    const searchSymbol = tokenList.find(
      (element: any) => element.chainId == 1 && element.address == l1TokenAddress.toLocaleLowerCase()
    )?.symbol;
    if (!searchSymbol) return zeroAddress;
    return tokenList.find((element: any) => element.chainId == 10 && element.symbol == searchSymbol).address;
  }
  if (l2ChainId == 137) {
    const response = await fetch(
      "https://raw.githubusercontent.com/maticnetwork/polygon-token-list/master/src/tokens/allTokens.json"
    );
    const body = await response.text();
    const tokenList = JSON.parse(body);
    const l2Address = tokenList.find(
      (element: any) => element.extensions.rootAddress == l1TokenAddress.toLowerCase()
    )?.address;
    return l2Address ?? zeroAddress;
  }
  if (l2ChainId == 42161) {
    const response = await fetch("https://bridge.arbitrum.io/token-list-42161.json");
    const body = await response.text();
    const tokenList = JSON.parse(body).tokens;
    const l2Address = tokenList.find(
      (element: any) => element.extensions.l1Address == l1TokenAddress.toLowerCase()
    )?.address;
    return l2Address ?? zeroAddress;
  }
  return zeroAddress;
}

async function _findL2TokenForOvmChain(l2ChainId: number, l1TokenAddress: string) {
  const ovmL2StandardERC20 = "0x4200000000000000000000000000000000000010";
  const l2Bridge = new ethers.Contract(ovmL2StandardERC20, ovmBridgeAbi as any, createConnectedVoidSigner(l2ChainId));

  const depositFinalizedEvents = await l2Bridge.queryFilter(
    l2Bridge.filters.DepositFinalized(l1TokenAddress),
    -4999,
    "latest"
  );

  if (depositFinalizedEvents.length === 0) return zeroAddress;
  return depositFinalizedEvents[0].args._l2Token;
}

const ovmBridgeAbi = [
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: "address", name: "_l1Token", type: "address" },
      { indexed: true, internalType: "address", name: "_l2Token", type: "address" },
      { indexed: true, internalType: "address", name: "_from", type: "address" },
      { indexed: false, internalType: "address", name: "_to", type: "address" },
      { indexed: false, internalType: "uint256", name: "_amount", type: "uint256" },
      { indexed: false, internalType: "bytes", name: "_data", type: "bytes" },
    ],
    name: "DepositFinalized",
    type: "event",
  },
];

export function createConnectedVoidSigner(networkId: number) {
  const nodeUrl = process.env[`NODE_URL_${networkId}`];
  if (!nodeUrl) throw new Error(`No NODE_URL_${networkId} set`);
  return new ethers.VoidSigner(zeroAddress).connect(new ethers.providers.JsonRpcProvider(nodeUrl));
}

async function askQuestion(query) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  return new Promise((resolve) =>
    rl.question(query, (ans) => {
      rl.close();
      resolve(ans);
    })
  );
}

export async function askYesNoQuestion(query) {
  const ans = (await askQuestion(`${query} (y/n) `)) as string;
  if (ans.toLowerCase() == "y") return true;
  if (ans.toLowerCase() == "n") return false;
  return askYesNoQuestion(query);
}
