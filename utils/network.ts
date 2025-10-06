import { PUBLIC_NETWORKS } from "./constants";

export function getNodeUrl(chainId: number): string {
  let url = process.env[`NODE_URL_${chainId}`] ?? process.env.CUSTOM_NODE_URL;
  if (url === undefined) {
    // eslint-disable-next-line no-console
    console.log(`No configured RPC provider for chain ${chainId}, reverting to public RPC.`);
    url = PUBLIC_NETWORKS[chainId].publicRPC;
  }

  return url;
}
