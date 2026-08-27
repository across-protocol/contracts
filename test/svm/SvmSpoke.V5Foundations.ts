import { assert } from "chai";
import { ethers } from "ethers";
import { PublicKey } from "@solana/web3.js";
import { createHash } from "crypto";
import { readFileSync } from "fs";

const fixture = JSON.parse(readFileSync("programs/svm-spoke/fixtures/v5_adapter_v1.json", "utf8"));

const fromHex = (value: string): Buffer => Buffer.from(value.slice(2), "hex");
const hex = (value: Uint8Array): string => `0x${Buffer.from(value).toString("hex")}`;
const raw = (value: number): Buffer => Buffer.alloc(32, value);
const u16 = (value: number): Buffer => {
  const encoded = Buffer.alloc(2);
  encoded.writeUInt16LE(value);
  return encoded;
};
const u32 = (value: number): Buffer => {
  const encoded = Buffer.alloc(4);
  encoded.writeUInt32LE(value);
  return encoded;
};
const u64 = (value: string): Buffer => {
  const encoded = Buffer.alloc(8);
  encoded.writeBigUInt64LE(BigInt(value));
  return encoded;
};
const word = (value: string): Buffer =>
  Buffer.from(ethers.utils.zeroPad(ethers.BigNumber.from(value).toHexString(), 32));

describe("svm_spoke V5 foundations", () => {
  const gateway = new PublicKey(fixture.programs.gateway);
  const svmSpoke = new PublicKey(fixture.programs.svmSpoke);

  it("matches the EVM deposit-ID and JIT-signature vectors", () => {
    const syntheticNonce = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "uint256"],
        [fixture.context.submitter, fixture.context.pathId, fixture.deposit.depositNonce]
      )
    );
    assert.equal(syntheticNonce, fixture.deposit.syntheticNonce);
    assert.equal(
      ethers.utils.keccak256(
        ethers.utils.solidityPack(
          ["bytes32", "bytes32", "bytes32"],
          [fixture.programs.gatewayBytes, fixture.deposit.depositor, syntheticNonce]
        )
      ),
      fixture.deposit.depositId
    );

    const nameHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ACXV.AcrossDepositDelegateAdapter.V1"));
    assert.equal(nameHash, fixture.jit.nameHash);
    const domain = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(["bytes32", "bytes32"], [nameHash, fixture.programs.gatewayBytes])
    );
    assert.equal(domain, fixture.jit.domain);
    const digest = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "uint256", "uint256", "bytes32"],
        [
          domain,
          fixture.context.pathId,
          fixture.deposit.depositNonce,
          fixture.jit.newOutputAmount,
          fixture.jit.newExclusiveRelayer,
        ]
      )
    );
    assert.equal(digest, fixture.jit.digest);
    assert.equal(ethers.utils.recoverAddress(digest, fixture.jit.signature), fixture.jit.authority);

    const curveN = ethers.BigNumber.from("0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
    assert.isTrue(ethers.BigNumber.from(ethers.utils.splitSignature(fixture.jit.signature).s).lte(curveN.div(2)));
    assert.isTrue(ethers.BigNumber.from(`0x${fixture.jit.highSSignature.slice(66, 130)}`).gt(curveN.div(2)));
  });

  it("matches the strict Borsh Deposit and Fill wires", () => {
    const authority = fromHex(fixture.jit.authority);
    const depositParams = Buffer.concat([
      fromHex(fixture.deposit.depositor),
      fromHex(fixture.deposit.recipient),
      fromHex(fixture.deposit.inputToken),
      fromHex(fixture.deposit.outputToken),
      u64(fixture.deposit.inputAmount),
      fromHex(fixture.deposit.outputAmount),
      u64(fixture.deposit.destinationChainId),
      fromHex(fixture.deposit.exclusiveRelayer),
      u64(fixture.deposit.depositNonce),
      u32(fixture.deposit.quoteTimestamp),
      u32(fixture.deposit.fillDeadline),
      u32(fixture.deposit.exclusivityParameter),
    ]);
    const depositInput = Buffer.concat([
      Buffer.from([fixture.version, 0]),
      depositParams,
      fromHex(fixture.deposit.dstStepId),
      Buffer.from([fixture.deposit.inputAmountMode.discriminant]),
      u16(fixture.deposit.inputAmountMode.bips),
      authority,
      Buffer.from([1, 1]),
    ]);
    assert.equal(hex(depositInput), fixture.wire.depositInput);

    const depositJit = Buffer.concat([
      fromHex(fixture.jit.newOutputAmount),
      fromHex(fixture.jit.newExclusiveRelayer),
      fromHex(fixture.jit.signature),
    ]);
    assert.equal(hex(depositJit), fixture.wire.depositJit);

    const fillInput = Buffer.concat([
      Buffer.from([fixture.version, 1]),
      fromHex(fixture.deposit.recipient),
      fromHex(fixture.deposit.outputToken),
      u64(fixture.fill.minOutputAmount),
      u32(0),
    ]);
    assert.equal(hex(fillInput), fixture.wire.fillInput);

    const fillJit = Buffer.concat([
      fromHex(fixture.deposit.depositor),
      fromHex(fixture.deposit.recipient),
      fromHex(fixture.jit.newExclusiveRelayer),
      fromHex(fixture.deposit.inputToken),
      fromHex(fixture.deposit.outputToken),
      word(fixture.deposit.inputAmount),
      u64(fixture.fill.outputAmount),
      u64(fixture.fill.originChainId),
      fromHex(fixture.deposit.depositId),
      u32(fixture.deposit.fillDeadline),
      u32(fixture.fill.exclusivityDeadline),
      u32(fromHex(fixture.fill.witness).length),
      fromHex(fixture.fill.witness),
      u64(fixture.fill.repaymentChainId),
      fromHex(fixture.fill.repaymentAddress),
    ]);
    assert.equal(hex(fillJit), fixture.wire.fillJit);
  });

  it("matches the Gateway dispatch bytes and all frozen PDA domains", () => {
    const discriminator = createHash("sha256").update("global:adapter_execute_across_v5").digest().subarray(0, 8);
    assert.equal(hex(discriminator), fixture.dispatch.discriminator);

    const input = fromHex(fixture.wire.depositInput);
    const jit = fromHex(fixture.wire.depositJit);
    const dispatch = Buffer.concat([
      discriminator,
      fromHex(fixture.context.borsh),
      u32(input.length),
      input,
      u32(jit.length),
      jit,
    ]);
    assert.equal(hex(dispatch), fixture.dispatch.data);

    const derive = (seeds: Buffer[], program: PublicKey): [string, number] => {
      const [key, bump] = PublicKey.findProgramAddressSync(seeds, program);
      return [key.toBase58(), bump];
    };
    const cases: Array<[[string, number], { address: string; bump: number }]> = [
      [derive([Buffer.from("dispatch_authority"), svmSpoke.toBuffer()], gateway), fixture.pdas.dispatchAuthority],
      [derive([Buffer.from("vault_authority")], gateway), fixture.pdas.gatewayVaultAuthority],
      [derive([Buffer.from("v5_source_delegate")], svmSpoke), fixture.pdas.sourceDelegate],
      [derive([Buffer.from("v5_fill_delegate")], svmSpoke), fixture.pdas.fillDelegate],
      [derive([Buffer.from("v5_fill_payer"), raw(0x11)], svmSpoke), fixture.pdas.fillPayer],
      [derive([Buffer.from("fills"), fromHex(fixture.deposit.depositId)], svmSpoke), fixture.pdas.fillStatus],
    ];
    for (const [[address, bump], expected] of cases) {
      assert.equal(address, expected.address);
      assert.equal(bump, expected.bump);
    }
  });
});
