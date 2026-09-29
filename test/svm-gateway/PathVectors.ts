import { assert } from "chai";
import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import fixture from "../../programs/svm-spoke/fixtures/v5_gateway_path.json";
import adapterFixture from "../../programs/svm-spoke/fixtures/v5_adapter_v1.json";
import { encodeDeposit, encodeFill, encodeJit, word } from "../svm/v5Encoding";
import { GATEWAY_COMMIT, PREFIX, floor, pair, pathId, tape, transfer } from "./reference";

describe("Gateway path cross-VM vectors", () => {
  it("checks shared Spoke encoders against the independent adapter fixture", () => {
    const bytes = (s: string) => Buffer.from(s.slice(2), "hex");
    const key = (s: string) => new PublicKey(bytes(s));
    const { deposit: d, fill: f, jit, wire } = adapterFixture;
    const deposit = {
      ...d,
      depositor: key(d.depositor),
      recipient: key(d.recipient),
      inputToken: key(d.inputToken),
      outputToken: key(d.outputToken),
      inputAmount: BigInt(d.inputAmount),
      outputAmount: bytes(d.outputAmount),
      destinationChainId: BigInt(d.destinationChainId),
      exclusiveRelayer: key(d.exclusiveRelayer),
      depositNonce: BigInt(d.depositNonce),
      dstStepId: bytes(d.dstStepId),
    };
    assert.deepEqual(
      encodeDeposit(
        deposit,
        { bips: d.inputAmountMode.bips },
        { authority: bytes(jit.authority), output: true, relayer: true }
      ),
      bytes(wire.depositInput)
    );
    assert.deepEqual(
      encodeFill(deposit.recipient, deposit.outputToken, BigInt(f.minOutputAmount)),
      bytes(wire.fillInput)
    );
    assert.deepEqual(
      encodeJit(
        {
          depositor: deposit.depositor,
          recipient: deposit.recipient,
          exclusiveRelayer: key(jit.newExclusiveRelayer),
          inputToken: deposit.inputToken,
          outputToken: deposit.outputToken,
          inputAmount: [...word(deposit.inputAmount)],
          outputAmount: new BN(f.outputAmount),
          originChainId: new BN(f.originChainId),
          depositId: [...bytes(d.depositId)],
          fillDeadline: d.fillDeadline,
          exclusivityDeadline: f.exclusivityDeadline,
          message: bytes(f.witness),
        },
        new BN(f.repaymentChainId),
        key(f.repaymentAddress)
      ),
      bytes(wire.fillJit)
    );
  });

  it("pins Borsh tape, EVM path hashing, sorted sibling root and V5 witness", () => {
    const bytes = (s: string) => Buffer.from(s.slice(2), "hex");
    const mint = new PublicKey(bytes(fixture.mint));
    const message = tape([
      floor(mint, BigInt(fixture.minimum)),
      transfer(mint, new PublicKey(bytes(fixture.recipient))),
    ]);
    assert.deepEqual(message, bytes(fixture.message));
    assert.equal(GATEWAY_COMMIT, fixture.gatewayCommit);
    const a = pathId({ chainId: BigInt(fixture.chainId), salt: bytes(fixture.salt), message });
    const b = pathId({ chainId: BigInt(fixture.chainId), salt: bytes(fixture.siblingSalt), message });
    assert.deepEqual(a, bytes(fixture.pathId));
    assert.deepEqual(b, bytes(fixture.siblingPathId));
    assert.deepEqual(pair(a, b), bytes(fixture.stepRoot));
    assert.deepEqual(pair(b, a), bytes(fixture.stepRoot));
    assert.deepEqual(Buffer.concat([PREFIX, pair(a, b)]), bytes(fixture.witness));
  });
});
