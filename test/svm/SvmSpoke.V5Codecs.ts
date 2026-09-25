import { assert } from "chai";
import { PublicKey } from "@solana/web3.js";
import { address } from "@solana/kit";
import adapterFixture from "../../programs/svm-spoke/fixtures/v5_adapter_v1.json";
import { SvmSpokeClient } from "../../src/svm/clients";
import * as SvmHelpers from "../../src/svm/web3-v1/helpers";
import * as SvmWeb3V1 from "../../src/svm/web3-v1";

const bytes = (hex: string) => Buffer.from(hex.slice(2), "hex");
const key = (hex: string) => address(new PublicKey(bytes(hex)).toBase58());

describe("SvmSpoke V5 client surface", () => {
  it("retires V4 delegate exports while retaining shared utilities and supported instructions", () => {
    for (const api of [SvmHelpers, SvmWeb3V1]) {
      for (const name of [
        "getDepositSeedHash",
        "getDepositPda",
        "getDepositNowSeedHash",
        "getDepositNowPda",
        "getFillRelayDelegateSeedHash",
        "getFillRelayDelegatePda",
        "DepositSeedData",
        "DepositNowSeedData",
      ]) {
        assert.notProperty(api, name);
      }
      assert.isFunction(api.getSolanaChainId);
      assert.isFunction(api.isSolanaDevnet);
    }
    assert.isFunction(SvmWeb3V1.calculateRelayHashUint8Array);
    assert.isFunction(SvmWeb3V1.relayerRefundHashFn);
    assert.isFunction(SvmWeb3V1.loadExecuteRelayerRefundLeafParams);
    assert.isFunction(SvmWeb3V1.closeInstructionParams);
    assert.isFunction(SvmSpokeClient.getAdapterExecuteAcrossV5Instruction);
    assert.isFunction(SvmSpokeClient.getGetUnsafeDepositIdInstruction);
    assert.containsAllKeys(
      SvmSpokeClient,
      ["V5AdapterInput", "AcrossDepositJitParams", "V5FillJit"].flatMap((type) =>
        ["Encoder", "Decoder", "Codec"].map((suffix) => `get${type}${suffix}`)
      )
    );
  });

  for (const literal of [false, true]) {
    it(`encodes the public DepositV1 input with ${literal ? "literal" : "balance-relative"} amounts`, () => {
      const { deposit, jit, wire } = adapterFixture;
      const value: SvmSpokeClient.V5AdapterInputArgs = {
        __kind: "DepositV1",
        fields: [
          {
            depositParams: {
              depositor: key(deposit.depositor),
              recipient: key(deposit.recipient),
              inputToken: key(deposit.inputToken),
              outputToken: key(deposit.outputToken),
              inputAmount: BigInt(deposit.inputAmount),
              outputAmount: bytes(deposit.outputAmount),
              destinationChainId: BigInt(deposit.destinationChainId),
              exclusiveRelayer: key(deposit.exclusiveRelayer),
              depositNonce: BigInt(deposit.depositNonce),
              quoteTimestamp: deposit.quoteTimestamp,
              fillDeadline: deposit.fillDeadline,
              exclusivityParameter: deposit.exclusivityParameter,
            },
            dstStepId: bytes(deposit.dstStepId),
            inputAmountMode: literal
              ? { __kind: "Literal" }
              : { __kind: "InputVaultBalance", bips: deposit.inputAmountMode.bips },
            modificationRules: {
              authority: bytes(jit.authority),
              allowOutputAmount: true,
              allowExclusiveRelayer: true,
            },
          },
        ],
      };
      const codec = SvmSpokeClient.getV5AdapterInputCodec();
      const expected = bytes(literal ? wire.depositInputLiteral : wire.depositInput);
      assert.equal(expected[0], 0, "DepositV1 tag, without an account discriminator");
      assert.deepEqual(Buffer.from(codec.encode(value) as Uint8Array), expected);
      assert.deepEqual(Buffer.from(codec.encode(codec.decode(expected)) as Uint8Array), expected);
    });
  }

  it("encodes public deposit JIT with a fixed 65-byte signature", () => {
    const { jit, wire } = adapterFixture;
    const codec = SvmSpokeClient.getAcrossDepositJitParamsCodec();
    const value = {
      newOutputAmount: bytes(jit.newOutputAmount),
      newExclusiveRelayer: key(jit.newExclusiveRelayer),
      signature: bytes(jit.signature),
    };
    const expected = bytes(wire.depositJit);
    assert.lengthOf(value.signature, 65);
    assert.lengthOf(expected, 129);
    assert.deepEqual(Buffer.from(codec.encode(value) as Uint8Array), expected);
    assert.deepEqual(Buffer.from(codec.encode(codec.decode(expected)) as Uint8Array), expected);
  });

  it("encodes the public FillV1 input with its enum tag", () => {
    const { deposit, fill, wire } = adapterFixture;
    const codec = SvmSpokeClient.getV5AdapterInputCodec();
    const expected = bytes(wire.fillInput);
    const encoded = codec.encode({
      __kind: "FillV1",
      fields: [
        {
          recipient: key(deposit.recipient),
          outputToken: key(deposit.outputToken),
          minOutputAmount: BigInt(fill.minOutputAmount),
        },
      ],
    });
    assert.equal(expected[0], 1, "FillV1 tag, without an account discriminator");
    assert.deepEqual(Buffer.from(encoded as Uint8Array), expected);
    assert.deepEqual(Buffer.from(codec.encode(codec.decode(expected)) as Uint8Array), expected);
  });

  it("encodes public RelayData and V5FillJit codecs with the Rust golden bytes and no account discriminator", () => {
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
