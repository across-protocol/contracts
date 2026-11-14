import { assert } from "chai";
import { PublicKey } from "@solana/web3.js";
import { BN } from "@anchor-lang/core";
import adapterFixture from "../../programs/svm-spoke/fixtures/v5_adapter_v1.json";
import {
  encodeDeposit,
  encodeDepositJit,
  encodeFill,
  encodeJit,
  encodeRelay,
  encodeType,
  encodingProgram,
  word,
} from "./v5Encoding";
import * as SvmHelpers from "../../src/svm/web3-v1/helpers";
import * as SvmWeb3V1 from "../../src/svm/web3-v1";

const bytes = (hex: string) => Buffer.from(hex.slice(2), "hex");
const key = (hex: string) => new PublicKey(bytes(hex));

describe("SvmSpoke V5 IDL codecs", () => {
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
  });

  const roundTrip = (name: string, expected: Buffer) => {
    const coder = encodingProgram.coder.types;
    assert.deepEqual(coder.encode(name, coder.decode(name, expected)), expected);
  };

  for (const literal of [false, true]) {
    it(`encodes DepositV1 with ${literal ? "literal" : "balance-relative"} amounts`, () => {
      const { deposit, jit, wire } = adapterFixture;
      const encoded = encodeDeposit(
        {
          ...deposit,
          depositor: key(deposit.depositor),
          recipient: key(deposit.recipient),
          inputToken: key(deposit.inputToken),
          outputToken: key(deposit.outputToken),
          inputAmount: BigInt(deposit.inputAmount),
          outputAmount: bytes(deposit.outputAmount),
          destinationChainId: BigInt(deposit.destinationChainId),
          exclusiveRelayer: key(deposit.exclusiveRelayer),
          depositNonce: BigInt(deposit.depositNonce),
          dstStepId: bytes(deposit.dstStepId),
        },
        literal ? { literal: true } : { bips: deposit.inputAmountMode.bips },
        { authority: bytes(jit.authority), output: true, relayer: true }
      );
      const expected = bytes(literal ? wire.depositInputLiteral : wire.depositInput);
      assert.equal(expected[0], 0, "DepositV1 tag, without an account discriminator");
      assert.deepEqual(encoded, expected);
      roundTrip("v5AdapterInput", expected);
    });
  }

  it("encodes deposit JIT with a fixed 65-byte signature", () => {
    const { jit, wire } = adapterFixture;
    const signature = bytes(jit.signature);
    const expected = bytes(wire.depositJit);
    assert.lengthOf(signature, 65);
    assert.lengthOf(expected, 129);
    assert.deepEqual(encodeDepositJit(bytes(jit.newOutputAmount), key(jit.newExclusiveRelayer), signature), expected);
    roundTrip("acrossDepositJitParams", expected);
  });

  it("encodes FillV1 with its enum tag", () => {
    const { deposit, fill, wire } = adapterFixture;
    const expected = bytes(wire.fillInput);
    assert.equal(expected[0], 1, "FillV1 tag, without an account discriminator");
    assert.deepEqual(
      encodeFill(key(deposit.recipient), key(deposit.outputToken), BigInt(fill.minOutputAmount)),
      expected
    );
    roundTrip("v5AdapterInput", expected);
  });

  it("encodes RelayData and V5FillJit with the Rust golden bytes and no account discriminator", () => {
    const { deposit, fill, jit, wire } = adapterFixture;
    const relayData = {
      depositor: key(deposit.depositor),
      recipient: key(deposit.recipient),
      exclusiveRelayer: key(jit.newExclusiveRelayer),
      inputToken: key(deposit.inputToken),
      outputToken: key(deposit.outputToken),
      inputAmount: [...word(BigInt(deposit.inputAmount))],
      outputAmount: new BN(fill.outputAmount),
      originChainId: new BN(fill.originChainId),
      depositId: [...bytes(deposit.depositId)],
      fillDeadline: deposit.fillDeadline,
      exclusivityDeadline: fill.exclusivityDeadline,
      message: bytes(fill.witness),
    };
    const expected = bytes(wire.fillJit);
    const relayBytes = expected.subarray(0, expected.length - 40);
    assert.deepEqual(encodeType("relayData", relayData), relayBytes);
    assert.deepEqual(encodeRelay(relayData), relayBytes); // Independent manual relay-hash layout.
    assert.deepEqual(encodeJit(relayData, new BN(fill.repaymentChainId), key(fill.repaymentAddress)), expected);
    roundTrip("relayData", relayBytes);
    roundTrip("v5FillJit", expected);
  });
});
