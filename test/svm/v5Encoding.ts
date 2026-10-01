// Shared test-only Spoke wire layouts; golden-vector derivations stay independent.
import { BN } from "@coral-xyz/anchor";
import { address } from "@solana/kit";
import { PublicKey } from "@solana/web3.js";
import { RelayData } from "../../src/types/svm";
import { SvmSpokeClient } from "../../src/svm/clients";

import { u32, u64, vec } from "../svm-gateway/wire";
export { u16, u32, u64, vec, word } from "../svm-gateway/wire";

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
  Buffer.from(
    SvmSpokeClient.getV5AdapterInputEncoder().encode({
      __kind: "DepositV1",
      fields: [
        {
          depositParams: {
            ...deposit,
            depositor: address(deposit.depositor.toBase58()),
            recipient: address(deposit.recipient.toBase58()),
            inputToken: address(deposit.inputToken.toBase58()),
            outputToken: address(deposit.outputToken.toBase58()),
            exclusiveRelayer: address(deposit.exclusiveRelayer.toBase58()),
          },
          dstStepId,
          inputAmountMode:
            "literal" in amountMode ? { __kind: "Literal" } : { __kind: "InputVaultBalance", bips: amountMode.bips },
          modificationRules: {
            authority: rules.authority,
            allowOutputAmount: rules.output,
            allowExclusiveRelayer: rules.relayer,
          },
        },
      ],
    }) as Uint8Array
  );

export const encodeFill = (recipient: PublicKey, outputToken: PublicKey, minOutputAmount: bigint) =>
  Buffer.from(
    SvmSpokeClient.getV5AdapterInputEncoder().encode({
      __kind: "FillV1",
      fields: [
        { recipient: address(recipient.toBase58()), outputToken: address(outputToken.toBase58()), minOutputAmount },
      ],
    }) as Uint8Array
  );
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
  Buffer.from(
    SvmSpokeClient.getV5FillJitEncoder().encode({
      relayData: {
        ...relay,
        depositor: address(relay.depositor.toBase58()),
        recipient: address(relay.recipient.toBase58()),
        exclusiveRelayer: address(relay.exclusiveRelayer.toBase58()),
        inputToken: address(relay.inputToken.toBase58()),
        outputToken: address(relay.outputToken.toBase58()),
        inputAmount: Uint8Array.from(relay.inputAmount),
        outputAmount: BigInt(relay.outputAmount.toString()),
        originChainId: BigInt(relay.originChainId.toString()),
        depositId: Uint8Array.from(relay.depositId),
      },
      repaymentChainId: BigInt(repaymentChainId.toString()),
      repaymentAddress: address(repaymentAddress.toBase58()),
    }) as Uint8Array
  );
