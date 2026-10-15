// Runs outside the checkout. The packed JSON subpaths are the only contracts inputs to generation.
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { writeFileSync } = require("node:fs");
const { createFromRoot } = require("codama");
const { rootNodeFromAnchor } = require("@codama/nodes-from-anchor");
const { renderVisitor } = require("@codama/renderers-js");
const { address, getProgramDerivedAddress } = require("@solana/kit");

async function main() {
  const names = ["svm_spoke", "multicall_handler", "sponsored_cctp_src_periphery"];
  for (const name of names) {
    const idl = require(`@across-protocol/contracts/svm/idl/${name}.json`);
    assert.deepEqual(idl, require(`@across-protocol/contracts/dist/src/svm/assets/idl/${name}.json`));
    await createFromRoot(rootNodeFromAnchor(idl)).accept(renderVisitor(`generated/${name}`));
  }
  writeFileSync(
    "tsconfig.json",
    JSON.stringify({
      compilerOptions: { target: "es2021", module: "commonjs", strict: true, skipLibCheck: true, outDir: "compiled" },
      include: ["generated/**/*.ts"],
    })
  );
  execFileSync(process.execPath, [require.resolve("typescript/bin/tsc"), "-p", "tsconfig.json"], { stdio: "inherit" });
  const spoke = require("./compiled/svm_spoke");
  const idl = require("@across-protocol/contracts/svm/idl/svm_spoke.json");
  assert.deepEqual(
    (await import("@across-protocol/contracts/svm/idl/svm_spoke.json", { with: { type: "json" } })).default,
    idl
  );
  const program = address(idl.address);
  const zero = address("11111111111111111111111111111111");
  const bytes = new Uint8Array(32);
  const fillInput = { __kind: "FillV1", fields: [{ recipient: zero, outputToken: zero, minOutputAmount: 1n }] };
  const input = spoke.getV5AdapterInputEncoder().encode(fillInput);
  assert.equal(input[0], 1); // Frozen V5 FillV1 discriminant.
  assert.deepEqual(spoke.getV5AdapterInputDecoder().decode(input), fillInput);
  const depositInput = {
    __kind: "DepositV1",
    fields: [
      {
        depositParams: {
          depositor: zero,
          recipient: zero,
          inputToken: zero,
          outputToken: zero,
          inputAmount: 1n,
          outputAmount: bytes,
          destinationChainId: 1n,
          exclusiveRelayer: zero,
          depositNonce: 1n,
          quoteTimestamp: 1,
          fillDeadline: 2,
          exclusivityParameter: 0,
        },
        dstStepId: bytes,
        inputAmountMode: { __kind: "InputVaultBalance", bips: 5000 },
        modificationRules: { authority: new Uint8Array(20), allowOutputAmount: true, allowExclusiveRelayer: false },
      },
    ],
  };
  const depositInputBytes = spoke.getV5AdapterInputEncoder().encode(depositInput);
  assert.equal(depositInputBytes[0], 0); // Frozen V5 DepositV1 discriminant.
  assert.deepEqual(spoke.getV5AdapterInputDecoder().decode(depositInputBytes), depositInput);
  const depositJit = { newOutputAmount: bytes, newExclusiveRelayer: zero, signature: new Uint8Array(65) };
  const depositJitBytes = spoke.getAcrossDepositJitParamsEncoder().encode(depositJit);
  assert.equal(depositJitBytes.length, 129); // Fixed signature, not a Vec.
  assert.deepEqual(spoke.getAcrossDepositJitParamsDecoder().decode(depositJitBytes), depositJit);
  const fillJit = {
    relayData: {
      depositor: zero,
      recipient: zero,
      exclusiveRelayer: zero,
      inputToken: zero,
      outputToken: zero,
      inputAmount: bytes,
      outputAmount: 1n,
      originChainId: 1n,
      depositId: bytes,
      fillDeadline: 1,
      exclusivityDeadline: 0,
      message: new Uint8Array(),
    },
    repaymentChainId: 1n,
    repaymentAddress: zero,
  };
  const jitData = spoke.getV5FillJitEncoder().encode(fillJit);
  assert.deepEqual(spoke.getV5FillJitDecoder().decode(jitData), fillJit);
  const ix = await spoke.getAdapterExecuteAcrossV5InstructionAsync({
    dispatchAuthority: zero,
    state: zero,
    program,
    stepId: bytes,
    pathId: bytes,
    submitter: zero,
    input,
    jitData,
  });
  const [authority] = await getProgramDerivedAddress({
    programAddress: program,
    seeds: [Buffer.from("__event_authority")],
  });
  const instruction = idl.instructions.find((ix) => ix.name === "adapter_execute_across_v5");
  const authorityIndex = instruction.accounts.findIndex((account) => account.name === "event_authority");
  assert(authorityIndex >= 0, "Missing event_authority account in adapter IDL");
  assert.equal(ix.accounts[authorityIndex].address, authority);
  assert.deepEqual([...ix.data.slice(0, 8)], instruction.discriminator);
  assert.equal(typeof spoke.getStateDecoder, "function");
  const fillStatus = { status: spoke.FillStatus.Filled, rentRecipient: zero, fillDeadline: 42 };
  assert.deepEqual(spoke.getFillStatusAccountDecoder().decode(spoke.getFillStatusAccountEncoder().encode(fillStatus)), {
    discriminator: spoke.FILL_STATUS_ACCOUNT_DISCRIMINATOR,
    ...fillStatus,
  });
  assert.equal(typeof require("./compiled/multicall_handler").getHandleV3AcrossMessageInstruction, "function");
  assert.equal(typeof require("./compiled/sponsored_cctp_src_periphery").getDepositForBurnInstruction, "function");
  assert.equal(typeof require("@across-protocol/contracts/dist/utils/MerkleTree").MerkleTree, "function");
  const contracts = require("@across-protocol/contracts");
  for (const [name, exportName] of [
    ["message_transmitter_v2", "MessageTransmitterV2Idl"],
    ["token_messenger_minter_v2", "TokenMessengerMinterV2Idl"],
  ]) {
    assert.throws(() => require.resolve(`@across-protocol/contracts/svm/idl/${name}.json`), {
      code: "MODULE_NOT_FOUND",
    });
    assert.deepEqual(contracts[exportName], require(`@across-protocol/contracts/dist/src/svm/assets/idl/${name}.json`));
  }
  assert.equal(typeof contracts.MessageTransmitterV2Client.getMessageTransmitterDecoder, "function");
  assert.equal(typeof contracts.TokenMessengerMinterV2Client.getDepositForBurnInstruction, "function");
  assert.equal(typeof contracts.MulticallHandlerCoder, "function");
  for (const name of [
    "SvmSpokeClient",
    "MulticallHandlerClient",
    "SponsoredCctpSrcPeripheryClient",
    "MessageTransmitterV2Client",
    "TokenMessengerMinterV2Client",
  ])
    assert.equal(typeof contracts[name], "object");
  assert.equal(typeof contracts.getDeployedAddress, "function");
  console.log("Packed IDLs: three public clients compile; Circle compatibility exports, V5 codecs and PDAs pass.");
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
