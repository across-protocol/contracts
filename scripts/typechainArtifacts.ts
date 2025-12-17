import fs from "fs";
import path from "path";
import fg from "fast-glob";

type ArtifactJson = {
  contractName?: string;
  [key: string]: unknown;
};

const OUT_DIR = "out";
const STAGE_DIR = ".typechain-artifacts";

function main() {
  if (fs.existsSync(STAGE_DIR)) {
    fs.rmdirSync(STAGE_DIR, { recursive: true });
  }
  fs.mkdirSync(STAGE_DIR, { recursive: true });

  const files = fg.sync([`${OUT_DIR}/**/*.json`, `!${OUT_DIR}/build-info/**`], {
    dot: false,
    onlyFiles: true,
  });

  const seen = new Map<string, string>(); // contractName -> first file path kept
  const dups: Array<{ name: string; kept: string; dropped: string }> = [];

  for (const file of files) {
    const name = file.split("/").pop()?.split(".")[0];
    if (!name) continue;

    const already = seen.get(name);
    if (already) {
      dups.push({ name, kept: already, dropped: file });
      continue;
    }

    seen.set(name, file);

    // One artifact per name => stable TypeChain inputs
    const dest = path.join(STAGE_DIR, `${name}.json`);
    fs.copyFileSync(file, dest);
  }

  if (dups.length > 0) {
    console.warn(`\nTypeChain dedupe: dropped ${dups.length} duplicate contract names:\n`);
  }

  console.log(`Staged ${seen.size} unique artifacts into ${STAGE_DIR}/`);
}

main();
