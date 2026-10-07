// Exercise the verified production binary in a fresh ledger, without the test feature.
import { spawnSync } from "child_process";
import { createHash } from "crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { Keypair } from "@solana/web3.js";
import { withLocalValidator } from "./localValidator";
import legacyAccount from "../../test/svm/accounts/legacy_requested_slow_fill.json";

async function main() {
  const work = mkdtempSync(path.join(tmpdir(), "svm-production-"));
  const binary = path.resolve("target/deploy/svm_spoke.so");
  console.log(`Production Spoke SHA-256: ${createHash("sha256").update(readFileSync(binary)).digest("hex")}`);
  const walletPath = path.resolve("test/svm/keys/localnet-wallet.json");
  const wallet = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(walletPath, "utf8"))));
  // Preserve the historical account layout, but expire it at timestamp 1. A mocked
  // clock left at zero cannot close this account; the production Clock sysvar can.
  const data = Buffer.from(legacyAccount.account.data[0], "base64");
  data.writeUInt32LE(1, data.length - 4);
  const fixturePath = path.join(work, "expired-fill.json");
  writeFileSync(
    fixturePath,
    JSON.stringify({
      ...legacyAccount,
      account: { ...legacyAccount.account, data: [data.toString("base64"), "base64"] },
    })
  );
  await withLocalValidator(
    {
      ledger: path.join(work, "ledger"),
      logPath: path.join(work, "validator.log"),
      mint: wallet.publicKey.toBase58(),
      args: [
        "--upgradeable-program",
        legacyAccount.account.owner,
        binary,
        wallet.publicKey.toBase58(),
        "--account",
        legacyAccount.pubkey,
        fixturePath,
      ],
    },
    (url) => {
      const result = spawnSync(
        "yarn",
        [
          "ts-mocha",
          "--bail",
          "-p",
          "tsconfig.json",
          "-t",
          "60000",
          "test/svm-production/Production.ts",
          "test/svm/SvmSpoke.EventAuthority.ts",
        ],
        {
          stdio: "inherit",
          env: {
            ...process.env,
            ANCHOR_PROVIDER_URL: url,
            ANCHOR_WALLET: walletPath,
            NODE_OPTIONS: "--no-experimental-strip-types",
          },
        }
      );
      if (result.error || result.status !== 0) throw new Error(`Production checks failed; logs: ${work}`);
    }
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
