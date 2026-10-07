// Separate validator: the ordinary Anchor suite installs mock_gateway at the
// same address. Build the foreign programs from immutable source checkouts.
import { spawnSync } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { prepareGatewayCheckout, preparePinnedCheckout, withLocalValidator } from "./localValidator";
import { Keypair } from "@solana/web3.js";
import { SWAP_COMMIT, SWAP_PROGRAM, swapGenesis } from "../../test/svm-gateway/swapFixture";
import { GATEWAY, PREFUNDED, GATEWAY_COMMIT } from "../../test/svm-gateway/reference";

function run(command: string, args: string[], cwd = process.cwd(), env = process.env) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", env });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
}
function buildSbf(command: string, args: string[], cwd = process.cwd(), env = process.env) {
  run("bash", [path.join(__dirname, "buildHelpers/runSbfBuild.sh"), command, ...args], cwd, env);
}
async function main() {
  const work = mkdtempSync(path.join(tmpdir(), "acp184-gateway-"));
  const checkout = prepareGatewayCheckout(work);
  const swapCheckout = preparePinnedCheckout({
    name: "Swap",
    repository: "https://github.com/raydium-io/raydium-cp-swap.git",
    commit: SWAP_COMMIT,
    destination: path.join(work, "raydium-cp-swap"),
    existing: process.env.SVM_SWAP_CHECKOUT,
  });
  buildSbf(
    "cargo",
    [
      "build-sbf",
      "--tools-version",
      "v1.52",
      "--manifest-path",
      "programs/cp-swap/Cargo.toml",
      "--sbf-out-dir",
      "target/deploy",
      "--",
      "--locked",
    ],
    swapCheckout
  );
  const foreignAnchor = process.env.SVM_GATEWAY_ANCHOR || "anchor";
  const gatewayIdlDir = path.join(work, "idl");
  mkdirSync(gatewayIdlDir);
  for (const name of ["gateway", "prefunded_adapter", "authority_requirement_planner"]) {
    buildSbf(foreignAnchor, ["build", "--program-name", name, "--ignore-keys", "--no-idl", "--", "--locked"], checkout);
    run(
      foreignAnchor,
      ["idl", "build", "--program-name", name, "--out", path.join(gatewayIdlDir, `${name}.json`), "--", "--locked"],
      checkout
    );
  }
  // IS_TEST is not sufficient for local Anchor builds: pass the feature explicitly.
  const spokeAnchor = process.env.SVM_SPOKE_ANCHOR || "anchor";
  // Keep native Cargo output separate from Docker-owned verified-build caches.
  const spokeEnv = {
    ...process.env,
    CARGO_TARGET_DIR: path.resolve(process.env.SVM_SPOKE_BUILD_ROOT || "target/real-gateway-spoke"),
  };
  buildSbf(
    "cargo",
    [
      "build-sbf",
      "--tools-version",
      "v1.54",
      "--manifest-path",
      "programs/svm-spoke/Cargo.toml",
      "--sbf-out-dir",
      path.join(work, "spoke"),
      "--features",
      "test",
      "--",
      "--locked",
    ],
    process.cwd(),
    spokeEnv
  );
  for (const directory of ["target/idl", "target/types"]) mkdirSync(directory, { recursive: true });
  run(
    spokeAnchor,
    [
      "idl",
      "build",
      "--program-name",
      "svm_spoke",
      "--out",
      "target/idl/svm_spoke.json",
      "--out-ts",
      "target/types/svm_spoke.ts",
      "--",
      "--locked",
      "--features",
      "test",
    ],
    process.cwd(),
    spokeEnv
  );

  const spokeId = JSON.parse(readFileSync("target/idl/svm_spoke.json", "utf8")).address;
  const plannerId = JSON.parse(
    readFileSync(path.join(gatewayIdlDir, "authority_requirement_planner.json"), "utf8")
  ).address;
  const walletPath = path.resolve("test/svm/keys/localnet-wallet.json");
  const wallet = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(walletPath, "utf8"))));
  const logPath = path.join(work, "validator.log");
  await withLocalValidator(
    {
      ledger: path.join(work, "ledger"),
      logPath,
      mint: wallet.publicKey.toBase58(),
      args: [
        ...(await swapGenesis(work)),
        "--upgradeable-program",
        SWAP_PROGRAM.toBase58(),
        path.join(swapCheckout, "target/deploy/raydium_cp_swap.so"),
        wallet.publicKey.toBase58(),
        "--upgradeable-program",
        GATEWAY.toBase58(),
        path.join(checkout, "target/deploy/gateway.so"),
        wallet.publicKey.toBase58(),
        "--upgradeable-program",
        PREFUNDED.toBase58(),
        path.join(checkout, "target/deploy/prefunded_adapter.so"),
        wallet.publicKey.toBase58(),
        "--upgradeable-program",
        plannerId,
        path.join(checkout, "target/deploy/authority_requirement_planner.so"),
        wallet.publicKey.toBase58(),
        "--upgradeable-program",
        spokeId,
        path.join(work, "spoke/svm_spoke.so"),
        wallet.publicKey.toBase58(),
      ],
    },
    (url) => {
      console.log(`Real Gateway ${GATEWAY_COMMIT}; Raydium CPMM ${SWAP_COMMIT}; validator logs: ${logPath}`);
      const tests = spawnSync(
        "yarn",
        [
          "ts-mocha",
          "--bail",
          "-p",
          "tsconfig.json",
          "-t",
          "1000000",
          "test/svm-gateway/PathVectors.ts",
          "test/svm-gateway/RealGateway.ts",
          ...process.argv.slice(2),
        ],
        {
          stdio: "inherit",
          env: {
            ...process.env,
            ANCHOR_PROVIDER_URL: url,
            ANCHOR_WALLET: walletPath,
            SVM_GATEWAY_IDL_DIR: gatewayIdlDir,
            NODE_OPTIONS: "--no-experimental-strip-types",
          },
        }
      );
      if (tests.error || tests.status !== 0) throw new Error(`Real-Gateway tests failed; see ${logPath}`);
    }
  );
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
