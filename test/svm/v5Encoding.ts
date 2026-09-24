// Shared test-only Spoke wire layouts; golden-vector derivations stay independent.
import { BN } from "@coral-xyz/anchor";
import { address } from "@solana/kit";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { RelayData } from "../../src/types/svm";
import { SvmSpokeClient } from "../../src/svm/clients";

export const u16 = (n: number) => {
  const b = Buffer.alloc(2);
  b.writeUInt16LE(n);
  return b;
};
export const u32 = (n: number) => {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
};
export const u64 = (n: bigint | number | BN) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n.toString()));
  return b;
};
export const word = (n: bigint | number) =>
  Buffer.from(ethers.utils.zeroPad(ethers.BigNumber.from(n.toString()).toHexString(), 32));
export const vec = (b: Buffer) => Buffer.concat([u32(b.length), b]);

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
  deposit: DepositFields,
  amountMode: { literal: true } | { bips: number },
  rules: { authority: Buffer; output: boolean; relayer: boolean } = {
    authority: Buffer.alloc(20),
    output: false,
    relayer: false,
  }
) =>
  Buffer.concat([
    Buffer.from([0]),
    deposit.depositor.toBuffer(),
    deposit.recipient.toBuffer(),
    deposit.inputToken.toBuffer(),
    deposit.outputToken.toBuffer(),
    u64(deposit.inputAmount),
    deposit.outputAmount,
    u64(deposit.destinationChainId),
    deposit.exclusiveRelayer.toBuffer(),
    u64(deposit.depositNonce),
    u32(deposit.quoteTimestamp),
    u32(deposit.fillDeadline),
    u32(deposit.exclusivityParameter),
    deposit.dstStepId,
    "literal" in amountMode ? Buffer.from([0]) : Buffer.concat([Buffer.from([1]), u16(amountMode.bips)]),
    rules.authority,
    Buffer.from([Number(rules.output), Number(rules.relayer)]),
  ]);

export const encodeFill = (recipient: PublicKey, outputToken: PublicKey, minOutputAmount: bigint) =>
  Buffer.concat([Buffer.from([1]), recipient.toBuffer(), outputToken.toBuffer(), u64(minOutputAmount)]);
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
