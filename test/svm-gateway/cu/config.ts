import { Keypair, PublicKey } from "@solana/web3.js";
import { createHash } from "crypto";

export const LEGACY_COMMIT = "7445f72de17900544605c7e6706c5fb3b3784738";
export const VALIDATOR_VERSION = "4.1.2";
export const SPOKE = new PublicKey("DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru");
export const SAMPLES = [0, 1, 2, 3, 4];
export const AMOUNT = 500_000n;
export const CHAIN_ID = 420n;
export const NOW = 1_800_000_000;
// Gateway reads the real Clock; keep authorization bytes fixed without depending on the host's current second.
export const FUNDING_DEADLINE = 0xffffffffffffffffn;
export const seed = (label: string) => createHash("sha256").update(`across-cu-v1:${label}`).digest();
export const keypair = (label: string) => Keypair.fromSeed(seed(label));
export const WALLET = keypair("payer");
export const CASES = ["legacy-deposit", "legacy-fill", "v5-deposit", "v5-external-fill", "v5-inplace-fill"] as const;
export type Case = (typeof CASES)[number];
export type Measurement = {
  case: Case;
  sample: number;
  execution: number;
  approval: number;
  buffer: number;
  total: number;
  fixture: Record<string, string | number>;
};
