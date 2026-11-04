// Shared test-only Spoke wire layouts; golden-vector derivations stay independent.
import { BN, IdlTypes, Program } from "@anchor-lang/core";
import { Connection, PublicKey } from "@solana/web3.js";
import { RelayData } from "../../src/types/svm";
import { SvmSpokeIdl, SvmSpokeAnchor } from "../../src/svm/assets";

import { u32, u64, vec } from "../svm-gateway/wire";
export { u16, u32, u64, vec, word } from "../svm-gateway/wire";

// The enriched production IDL includes Rust types carried inside opaque adapter bytes.
// An explicit connection keeps offline codecs/builders independent of Anchor's wallet environment.
export const encodingProgram = new Program<SvmSpokeAnchor>(SvmSpokeIdl, {
  connection: new Connection("http://127.0.0.1:8899"),
});
type SpokeTypes = IdlTypes<SvmSpokeAnchor>;
export const encodeType = <T extends keyof SpokeTypes>(name: T, value: SpokeTypes[T]) =>
  encodingProgram.coder.types.encode(name, value);

export type DepositFields = {
  depositor: PublicKey;
  recipient: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: bigint;
  outputAmount: Buffer;
  destinationChainId: bigint;
  exclusiveRelayer: PublicKey;
  depositNonce: bigint;
  quoteTimestamp: number;
  fillDeadline: number;
  exclusivityParameter: number;
  dstStepId: Buffer;
};

export const encodeDeposit = (
  { dstStepId, ...deposit }: DepositFields,
  amountMode: { literal: true } | { bips: number },
  rules: { authority: Buffer; output: boolean; relayer: boolean } = {
    authority: Buffer.alloc(20),
    output: false,
    relayer: false,
  }
) =>
  encodeType("v5AdapterInput", {
    depositV1: [
      {
        depositParams: {
          ...deposit,
          inputAmount: new BN(deposit.inputAmount.toString()),
          outputAmount: [...deposit.outputAmount],
          destinationChainId: new BN(deposit.destinationChainId.toString()),
          depositNonce: new BN(deposit.depositNonce.toString()),
        },
        dstStepId: [...dstStepId],
        inputAmountMode: "literal" in amountMode ? { literal: {} } : { inputVaultBalance: { bips: amountMode.bips } },
        modificationRules: {
          authority: [...rules.authority],
          allowOutputAmount: rules.output,
          allowExclusiveRelayer: rules.relayer,
        },
      },
    ],
  });

export const encodeFill = (recipient: PublicKey, outputToken: PublicKey, minOutputAmount: bigint) =>
  encodeType("v5AdapterInput", {
    fillV1: [{ recipient, outputToken, minOutputAmount: new BN(minOutputAmount.toString()) }],
  });
export const encodeRelay = (relay: RelayData) =>
  Buffer.concat([
    relay.depositor.toBuffer(),
    relay.recipient.toBuffer(),
    relay.exclusiveRelayer.toBuffer(),
    relay.inputToken.toBuffer(),
    relay.outputToken.toBuffer(),
    Buffer.from(relay.inputAmount),
    u64(relay.outputAmount),
    u64(relay.originChainId),
    Buffer.from(relay.depositId),
    u32(relay.fillDeadline),
    u32(relay.exclusivityDeadline),
    vec(relay.message),
  ]);
export const encodeJit = (relay: RelayData, repaymentChainId: bigint | number | BN, repaymentAddress: PublicKey) =>
  encodeType("v5FillJit", {
    relayData: relay,
    repaymentChainId: new BN(repaymentChainId.toString()),
    repaymentAddress,
  });

export const encodeDepositJit = (outputAmount: Buffer, exclusiveRelayer: PublicKey, signature: Uint8Array) =>
  encodeType("acrossDepositJitParams", {
    newOutputAmount: [...outputAmount],
    newExclusiveRelayer: exclusiveRelayer,
    signature: [...signature],
  });
