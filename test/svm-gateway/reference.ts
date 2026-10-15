// Conformance facade: generated Spoke codecs plus the shared Gateway wire format.
import { PublicKey } from "@solana/web3.js";
import { encodeDeposit, encodeFill, encodeJit } from "../svm/v5Encoding";
import { word } from "./wire";
export * from "./wire";

export const fillInput = encodeFill;
export const fillJit = (relay: Parameters<typeof encodeJit>[0], repayment: PublicKey) =>
  encodeJit(relay, 1n, repayment);
export type Deposit = {
  depositor: PublicKey;
  recipient: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: bigint;
  outputAmount: bigint;
  destinationChainId: bigint;
  nonce: bigint;
  quoteTimestamp: number;
  fillDeadline: number;
  dstStepId: Buffer;
};
export const depositInput = (d: Deposit) =>
  encodeDeposit(
    {
      ...d,
      outputAmount: word(d.outputAmount),
      exclusiveRelayer: PublicKey.default,
      depositNonce: d.nonce,
      exclusivityParameter: 0,
    },
    { bips: 10000 }
  );
