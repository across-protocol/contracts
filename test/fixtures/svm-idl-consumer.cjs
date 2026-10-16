// Runs outside the checkout. The packed JSON subpaths are the only contracts inputs to generation.
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { existsSync, readFileSync, writeFileSync } = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const { createFromRoot } = require("codama");
const { rootNodeFromAnchor } = require("@codama/nodes-from-anchor");
const { renderVisitor } = require("@codama/renderers-js");
const { address, getProgramDerivedAddress } = require("@solana/kit");

async function main() {
  const names = ["svm_spoke", "multicall_handler", "sponsored_cctp_src_periphery"];
  for (const name of names) {
    const idl = require(`@across-protocol/contracts/svm/idl/${name}.json`);
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
  // Check generated API conformance at the publication boundary. SDK-owned generation
  // must retain these cases in its own suite.
  for (const name of [
    "Deposit",
    "DepositNow",
    "UnsafeDeposit",
    "FillRelay",
    "GetUnsafeDepositId",
    "RequestSlowFill",
    "ExecuteSlowRelayLeaf",
  ]) {
    assert.equal(spoke[`get${name}Instruction`], undefined);
    assert.equal(spoke[`get${name}InstructionAsync`], undefined);
  }
  assert.equal(typeof spoke.getAdapterExecuteAcrossV5Instruction, "function");
  for (const suffix of ["Encoder", "Decoder", "Codec"]) {
    assert.equal(spoke[`getFillRelayParams${suffix}`], undefined);
    for (const name of ["V5AdapterInput", "AcrossDepositJitParams", "RelayData", "V5FillJit"])
      assert.equal(typeof spoke[`get${name}${suffix}`], "function");
  }
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
  assert.equal(ix.accounts[authorityIndex].role, 0); // Readonly, not a transaction signer.
  assert.deepEqual([...ix.data.slice(0, 8)], instruction.discriminator);
  assert.equal(typeof spoke.getStateDecoder, "function");
  const fillStatus = { status: spoke.FillStatus.Filled, rentRecipient: zero, fillDeadline: 42 };
  assert.deepEqual(spoke.getFillStatusAccountDecoder().decode(spoke.getFillStatusAccountEncoder().encode(fillStatus)), {
    discriminator: spoke.FILL_STATUS_ACCOUNT_DISCRIMINATOR,
    ...fillStatus,
  });
  assert.equal(typeof require("./compiled/multicall_handler").getHandleV3AcrossMessageInstruction, "function");
  assert.equal(typeof require("./compiled/sponsored_cctp_src_periphery").getDepositForBurnInstruction, "function");
  // Shared consumers must not load an SVM runtime, even when fixture dependencies happen to be installed.
  const load = Module._load;
  let contracts;
  try {
    Module._load = function (request, ...args) {
      assert(!/^(@solana(?:-program)?\/|@anchor-lang\/|@codama\/|codama$|bs58$|buffer-layout$)/.test(request), request);
      return load.call(this, request, ...args);
    };
    contracts = require("@across-protocol/contracts");
  } finally {
    Module._load = load;
  }
  const packageRoot = path.dirname(require.resolve("@across-protocol/contracts/package.json"));
  const metadata = require("@across-protocol/contracts/package.json");
  assert(
    !Object.keys(metadata.dependencies).some((name) =>
      /^(@solana|@anchor-lang|@codama|codama|bs58|buffer-layout)/.test(name)
    )
  );
  assert(!existsSync(path.join(packageRoot, "dist/src/svm/index.js")));
  for (const name of [
    "SvmSpoke",
    "MulticallHandler",
    "SponsoredCctpSrcPeriphery",
    "MessageTransmitterV2",
    "TokenMessengerMinterV2",
  ])
    for (const suffix of ["Client", "Idl", "Anchor"]) assert.equal(contracts[`${name}${suffix}`], undefined);
  for (const name of [
    "MulticallHandlerCoder",
    "AcrossPlusMessageCoder",
    "calculateRelayHashUint8Array",
    "findProgramAddress",
    "relayerRefundHashFn",
    "getCpiEventsFromTransaction",
    "createDefaultSolanaClient",
    "readProgramEvents",
  ])
    assert.equal(contracts[name], undefined);
  for (const subpath of [
    "dist/src/svm",
    "dist/src/svm/index.js",
    "dist/src/svm/web3-v1",
    "dist/src/svm/web3-v2",
    "dist/src/svm/web3-v1/coders",
    "dist/src/svm/web3-v2/types",
    "dist/src/svm/assets",
    "dist/src/svm/assets/svm_spoke",
    "dist/src/svm/clients/SvmSpoke",
    "dist/src/svm/clients/MessageTransmitterV2",
    ...[...names, "message_transmitter_v2", "token_messenger_minter_v2"].map(
      (name) => `dist/src/svm/assets/idl/${name}.json`
    ),
    "svm/idl/message_transmitter_v2.json",
    "svm/idl/token_messenger_minter_v2.json",
    "svm/idl/test.json",
    "dist/utils/internal",
    "dist/scripts/internal",
  ]) {
    assert.throws(() => require.resolve(`@across-protocol/contracts/${subpath}`), {
      code: "ERR_PACKAGE_PATH_NOT_EXPORTED",
    });
    assert(!existsSync(path.join(packageRoot, subpath)), `Internal path shipped: ${subpath}`);
  }
  const esm = await import("@across-protocol/contracts");
  assert.deepEqual(esm.default, contracts);
  for (const name of ["MerkleTree", "EMPTY_MERKLE_ROOT", "getDeployedAddress", "CHAIN_IDs", "getNodeUrl"])
    assert.equal(esm[name], contracts[name]);
  assert.equal(typeof contracts.getDeployedAddress, "function");
  const deployments = require("@across-protocol/contracts/dist/broadcast/deployed-addresses.json");
  const [chain, deployment] = Object.entries(deployments.chains).find(
    ([, value]) => Object.keys(value.contracts).length
  );
  const [contractName, info] = Object.entries(deployment.contracts)[0];
  assert.equal(contracts.getDeployedAddress(contractName, chain), info.address);
  assert.equal(contracts.getDeployedBlockNumber(contractName, Number(chain)), info.block_number);
  assert.equal(new contracts.MerkleTree([], (leaf) => leaf).getHexRoot(), contracts.EMPTY_MERKLE_ROOT);
  assert.equal(contracts.CHAIN_IDs.MAINNET, 1);
  process.env.NODE_URL_1 = "https://example.invalid";
  assert.equal(contracts.getNodeUrl(1), "https://example.invalid");
  const artifactPath = require.resolve("@across-protocol/contracts/dist/evm/artifacts/HubPool.sol/HubPool.json");
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  assert(artifact.abi.some(({ name }) => name === "proposeRootBundle"));
  assert.equal(typeof artifact.bytecode, "string");
  assert(
    readFileSync(require.resolve("@across-protocol/contracts/contracts/hub-pool/HubPool.sol"), "utf8").includes(
      "contract HubPool"
    )
  );
  const privateModules = [
    "index",
    "src/DeploymentUtils",
    "src/consts",
    "utils/index",
    "utils/MerkleTree",
    "utils/constants",
    "utils/network",
    "utils/utils",
  ];
  for (const subpath of [
    "dist",
    "dist/utils",
    ...privateModules.flatMap((name) => ["", ".js", ".d.ts"].map((suffix) => `dist/${name}${suffix}`)),
  ]) {
    assert.throws(() => require.resolve(`@across-protocol/contracts/${subpath}`), {
      code: "ERR_PACKAGE_PATH_NOT_EXPORTED",
    });
    await assert.rejects(import(`@across-protocol/contracts/${subpath}`), {
      code: "ERR_PACKAGE_PATH_NOT_EXPORTED",
    });
  }
  for (const name of ["src/consts", "utils/utils"])
    for (const suffix of [".js", ".d.ts"]) assert(!existsSync(path.join(packageRoot, `dist/${name}${suffix}`)));

  writeFileSync(
    "consumer.ts",
    `
import { MerkleTree, EMPTY_MERKLE_ROOT, getDeployedAddress, CHAIN_IDs, getNodeUrl } from "@across-protocol/contracts";
import idl from "@across-protocol/contracts/svm/idl/svm_spoke.json";
const tree: MerkleTree<string> = new MerkleTree<string>([], (leaf) => leaf);
const root: string = tree.getHexRoot() || EMPTY_MERKLE_ROOT;
getDeployedAddress("HubPool", CHAIN_IDs.MAINNET);
getNodeUrl(1);
const program: string = idl.address;
// @ts-expect-error SVM generated root exports have been removed.
import { SvmSpokeClient } from "@across-protocol/contracts";
// @ts-expect-error Anchor-generated types are internal.
import { SvmSpokeAnchor } from "@across-protocol/contracts";
// @ts-expect-error Deep generated clients are physically absent.
import * as client from "@across-protocol/contracts/dist/src/svm/clients/SvmSpoke";
// @ts-expect-error Handwritten SVM helpers are internal.
import { MulticallHandlerCoder } from "@across-protocol/contracts/dist/src/svm/web3-v1";
// @ts-expect-error Circle JSON is no longer a contracts package interface.
import circle from "@across-protocol/contracts/dist/src/svm/assets/idl/message_transmitter_v2.json";
`
  );
  for (const module of ["commonjs", "Node16"]) {
    // Legacy TS resolution ignores exports; Node16 must enforce the package boundary even for shipped internals.
    if (module === "Node16")
      writeFileSync(
        "consumer.ts",
        readFileSync("consumer.ts", "utf8") +
          privateModules
            .map(
              (name, i) =>
                `\n// @ts-expect-error Compiled implementation paths are private.\nimport * as private${i} from "@across-protocol/contracts/dist/${name}";\n`
            )
            .join("")
      );
    execFileSync(
      process.execPath,
      [
        require.resolve("typescript/bin/tsc"),
        "--noEmit",
        "--strict",
        "--skipLibCheck",
        "--esModuleInterop",
        "--resolveJsonModule",
        "--target",
        "es2021",
        "--module",
        module,
        "consumer.ts",
      ],
      { stdio: "inherit" }
    );
  }
  console.log(
    "Packed IDLs: three clients compile; V5 codecs/PDAs, removed runtime/types, and EVM/shared consumers pass."
  );
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
