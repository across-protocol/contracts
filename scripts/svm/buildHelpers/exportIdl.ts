import { mkdirSync, readdirSync, rmSync, writeFileSync } from "fs";
import { readProductionIdls } from "./productionIdls";

const idls = readProductionIdls("src/svm/assets/idl");
for (const directory of ["svm/idl", "dist/src/svm/assets/idl"]) {
  mkdirSync(directory, { recursive: true });
  // Preserve the compiled legacy index, but never carry stale JSON into a new package.
  for (const file of readdirSync(directory)) if (file.endsWith(".json")) rmSync(`${directory}/${file}`);
  for (const [name, contents] of idls) writeFileSync(`${directory}/${name}.json`, contents);
}
