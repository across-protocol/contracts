import { PublicKey } from "@solana/web3.js";
import { NATIVE_MINT } from "@solana/spl-token";
import { keypair, SPOKE } from "../cu/config";
import { GATEWAY, pda, u64 } from "../wire";
export { SPOKE, GATEWAY };
export const USDC = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
export const MINTS = [USDC, NATIVE_MINT];
export const POOL = new PublicKey("47hq28mcL7q5GhBg7epyGF2dnuJd4MKFt8QhT7CzYUp4");
export const CPMM = new PublicKey("CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C");
export const STATE = pda(SPOKE, Buffer.from("state"), u64(0));
export const VAULT_AUTHORITY = pda(GATEWAY, Buffer.from("vault_authority"));
export const EXECUTOR = pda(GATEWAY, Buffer.from("executor_authority"));
export const FEATURES = new PublicKey("Feature111111111111111111111111111111111111");
export const LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
export const MAINNET_GENESIS = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d";
export const payer = (sample: number) => keypair(`fork:${sample}:payer`);
export const recipient = (sample: number) => keypair(`fork:${sample}:recipient`);
export const CASES = [
  "deposit-cosigned",
  "deposit-step-delegate",
  "fill-external",
  "fill-inplace",
  "swap-deposit",
  "fill-swap",
  "fill-jit-swap",
] as const;
export type Flow = (typeof CASES)[number];
export function poolKeys(data: Buffer) {
  if (data.length < 637) throw new Error("Unexpected CPMM pool layout");
  const key = (index: number) => new PublicKey(data.subarray(8 + index * 32, 40 + index * 32));
  return { config: key(0), vault0: key(2), vault1: key(3), mint0: key(5), mint1: key(6), observation: key(9) };
}
