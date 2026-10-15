import { strict as assert } from "assert";
import { execFileSync } from "child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { productionIdlNames, publicIdlNames } from "../../scripts/svm/buildHelpers/productionIdls";

describe("Production IDL package", function () {
  this.timeout(120000);
  const root = path.resolve(__dirname, "../..");
  let work: string;
  beforeEach(() => {
    work = mkdtempSync(path.join(tmpdir(), "svm-idl-package-"));
  });
  afterEach(() => rmSync(work, { recursive: true, force: true }));

  function runHelper(name: string) {
    return execFileSync(
      process.execPath,
      [
        path.join(root, "node_modules/ts-node/dist/bin.js"),
        "--project",
        path.join(root, "tsconfig.json"),
        path.join(root, "scripts/svm/buildHelpers", `${name}.ts`),
      ],
      { cwd: work, encoding: "utf8", stdio: "pipe" }
    );
  }

  function prepareAssets() {
    cpSync(path.join(root, "src/svm/assets"), path.join(work, "src/svm/assets"), { recursive: true });
    cpSync(path.join(root, "idls"), path.join(work, "idls"), { recursive: true });
    cpSync(path.join(root, "src/svm/assets/idl"), path.join(work, "target/idl"), { recursive: true });
    mkdirSync(path.join(work, "target/types"), { recursive: true });
    for (const name of productionIdlNames)
      cpSync(path.join(root, `src/svm/assets/${name}.ts`), path.join(work, `target/types/${name}.ts`));
  }

  it("cleans stale test/mock/V1 artifacts and exports only approved production JSON", () => {
    prepareAssets();
    // A rebuild must also remove Circle JSON left by an older public export list.
    mkdirSync(path.join(work, "svm/idl"), { recursive: true });
    for (const name of ["message_transmitter_v2", "token_messenger_minter_v2"])
      writeFileSync(path.join(work, `svm/idl/${name}.json`), "{}");
    for (const name of ["test", "mock_gateway", "message_transmitter", "unexpected_program"]) {
      for (const dir of ["target/idl", "src/svm/assets/idl", "svm/idl", "dist/src/svm/assets/idl"]) {
        mkdirSync(path.join(work, dir), { recursive: true });
        writeFileSync(path.join(work, dir, `${name}.json`), "{}");
      }
      writeFileSync(path.join(work, `src/svm/assets/${name}.ts`), "export type Stale = never;");
    }
    runHelper("generateSvmAssets");
    runHelper("exportIdl");
    for (const dir of ["src/svm/assets/idl", "svm/idl", "dist/src/svm/assets/idl"])
      assert.deepEqual(
        readdirSync(path.join(work, dir))
          .filter((name) => name.endsWith(".json"))
          .sort(),
        (dir === "svm/idl" ? publicIdlNames : productionIdlNames).map((name) => `${name}.json`).sort()
      );
    assert(!readFileSync(path.join(work, "src/svm/assets/index.ts"), "utf8").includes("TestAnchor"));
    assert(!readdirSync(path.join(work, "src/svm/assets")).includes("test.ts"));
  });

  for (const [label, expectedError, mutate] of [
    [
      "test-feature instructions",
      /Test instruction in production IDL/,
      (idl: any) => idl.instructions.push({ name: "test_create_v5_fill_status", accounts: [] }),
    ],
    [
      "missing V5 schemas",
      /Missing V5 schema/,
      (idl: any) => (idl.types = idl.types.filter((type: any) => type.name !== "V5FillJit")),
    ],
    [
      "missing event-authority seeds",
      /Missing canonical event-authority PDA/,
      (idl: any) => {
        const instruction = idl.instructions.find((ix: any) =>
          ix.accounts.some((account: any) => account.name === "event_authority")
        );
        delete instruction.accounts.find((account: any) => account.name === "event_authority").pda;
      },
    ],
  ] as const) {
    it(`rejects ${label} before copying production assets`, () => {
      prepareAssets();
      for (const dir of ["target/idl", "src/svm/assets/idl"]) {
        const file = path.join(work, dir, "svm_spoke.json");
        const idl = JSON.parse(readFileSync(file, "utf8"));
        mutate(idl);
        writeFileSync(file, JSON.stringify(idl));
      }
      assert.throws(() => runHelper("generateSvmAssets"), expectedError);
      assert.throws(() => runHelper("exportIdl"), expectedError);
    });
  }

  it("rejects a test-feature sponsored CCTP layout alongside production Spoke", () => {
    prepareAssets();
    for (const dir of ["target/idl", "src/svm/assets/idl"]) {
      const file = path.join(work, dir, "sponsored_cctp_src_periphery.json");
      const idl = JSON.parse(readFileSync(file, "utf8"));
      idl.types.find((type: any) => type.name === "State").type.fields.push({ name: "current_time", type: "u64" });
      writeFileSync(file, JSON.stringify(idl));
    }
    for (const helper of ["generateSvmAssets", "exportIdl"])
      assert.throws(() => runHelper(helper), /Test-only current_time field in sponsored CCTP State/);
  });

  it("rejects missing approved IDLs and changes to reviewed Circle snapshots", () => {
    prepareAssets();
    const circle = path.join(work, "src/svm/assets/idl/message_transmitter_v2.json");
    const contents = readFileSync(circle, "utf8");
    writeFileSync(circle, contents + "\n");
    assert.throws(() => runHelper("exportIdl"), /Unreviewed Circle IDL/);
    rmSync(circle);
    assert.throws(() => runHelper("exportIdl"), /ENOENT/);
  });

  it("packs consumable JSON, preserves legacy/EVM paths, and generates clients outside the checkout", () => {
    // Exercise the actual npm pack lifecycle, including the clean TS build and EVM/IDL export.
    execFileSync(
      "npm",
      [
        "pack",
        "--silent",
        "--offline",
        "--update-notifier=false",
        "--pack-destination",
        work,
        "--cache",
        path.join(work, "npm-cache"),
      ],
      { cwd: root, encoding: "utf8", stdio: "pipe", timeout: 120000, maxBuffer: 10 * 1024 * 1024 }
    );
    const tarballs = readdirSync(work).filter((file) => file.endsWith(".tgz"));
    assert.equal(tarballs.length, 1);
    const tarball = path.join(work, tarballs[0]);
    const paths = execFileSync("tar", ["-tzf", tarball], { encoding: "utf8" })
      .trim()
      .split("\n")
      .map((file) => file.replace(/^package\//, ""));
    for (const prefix of ["svm/idl/", "dist/src/svm/assets/idl/"])
      assert.deepEqual(
        paths.filter((file) => file.startsWith(prefix) && file.endsWith(".json")).sort(),
        (prefix === "svm/idl/" ? publicIdlNames : productionIdlNames).map((name) => `${prefix}${name}.json`).sort()
      );
    assert(!paths.some((file) => /(?:^|\/)(?:test|mock_gateway)\.(?:json|js|d\.ts)$/.test(file)));
    for (const file of [
      "dist/index.js",
      "dist/index.d.ts",
      "dist/utils/MerkleTree.js",
      "dist/src/svm/clients/SvmSpoke/index.js",
      "dist/src/svm/web3-v1/index.js",
      "dist/evm/artifacts/HubPool.sol/HubPool.json",
      "contracts/hub-pool/HubPool.sol",
    ])
      assert(paths.includes(file), `Missing existing package path: ${file}`);

    const modules = path.join(work, "node_modules");
    const installed = path.join(modules, "@across-protocol/contracts");
    mkdirSync(installed, { recursive: true });
    execFileSync("tar", ["-xzf", tarball, "--strip-components=1", "-C", installed]);
    // Reuse installed tool dependencies offline, but resolve contracts exclusively from the tarball.
    for (const entry of readdirSync(path.join(root, "node_modules"))) {
      if (entry === "@across-protocol") {
        for (const dependency of readdirSync(path.join(root, "node_modules", entry)))
          if (dependency !== "contracts")
            symlinkSync(
              path.join(root, "node_modules", entry, dependency),
              path.join(modules, entry, dependency),
              "dir"
            );
      } else if (entry !== ".bin")
        symlinkSync(path.join(root, "node_modules", entry), path.join(modules, entry), "dir");
    }
    cpSync(path.join(root, "test/fixtures/svm-idl-consumer.cjs"), path.join(work, "consumer.cjs"));
    execFileSync(process.execPath, ["consumer.cjs"], { cwd: work, stdio: "inherit" });
  });
});
