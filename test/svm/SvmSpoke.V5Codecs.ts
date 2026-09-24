import { assert } from "chai";
import { PublicKey } from "@solana/web3.js";
import { address } from "@solana/kit";
import adapterFixture from "../../programs/svm-spoke/fixtures/v5_adapter_v1.json";
import { SvmSpokeClient } from "../../src/svm/clients";

describe("SvmSpoke V5 public codecs", () => {
  it("encodes public RelayData and V5FillJit codecs with the Rust golden bytes and no account discriminator", () => {
    const bytes = (hex: string) => Buffer.from(hex.slice(2), "hex");
    const key = (hex: string) => address(new PublicKey(bytes(hex)).toBase58());
    const { deposit, fill, jit, wire } = adapterFixture;
    const relayData = {
      depositor: key(deposit.depositor),
      recipient: key(deposit.recipient),
      exclusiveRelayer: key(jit.newExclusiveRelayer),
      inputToken: key(deposit.inputToken),
      outputToken: key(deposit.outputToken),
      inputAmount: bytes(`0x${BigInt(deposit.inputAmount).toString(16).padStart(64, "0")}`),
      outputAmount: BigInt(fill.outputAmount),
      originChainId: BigInt(fill.originChainId),
      depositId: bytes(deposit.depositId),
      fillDeadline: deposit.fillDeadline,
      exclusivityDeadline: fill.exclusivityDeadline,
      message: bytes(fill.witness),
    };
    const value = {
      relayData,
      repaymentChainId: BigInt(fill.repaymentChainId),
      repaymentAddress: key(fill.repaymentAddress),
    };
    const expected = bytes(wire.fillJit);
    const relayBytes = expected.subarray(0, expected.length - 40);
    const relayCodec = SvmSpokeClient.getRelayDataCodec();
    const jitCodec = SvmSpokeClient.getV5FillJitCodec();
    // Buffer.from copies the bytes; the cast bridges Kit's readonly byte type and this repo's TS version.
    assert.deepEqual(Buffer.from(relayCodec.encode(relayData) as Uint8Array), relayBytes);
    assert.deepEqual(Buffer.from(jitCodec.encode(value) as Uint8Array), expected);
    assert.deepEqual(Buffer.from(relayCodec.encode(relayCodec.decode(relayBytes)) as Uint8Array), relayBytes);
    assert.deepEqual(Buffer.from(jitCodec.encode(jitCodec.decode(expected)) as Uint8Array), expected);
  });
});
