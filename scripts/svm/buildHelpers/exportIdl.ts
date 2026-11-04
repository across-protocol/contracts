import { mkdirSync, readdirSync, rmSync, writeFileSync } from "fs";
import { publicIdlNames, readProductionIdls } from "./productionIdls";

const idls = readProductionIdls("src/svm/assets/idl");
for (const directory of ["svm/idl", "dist/src/svm/assets/idl"]) {
  mkdirSync(directory, { recursive: true });
  // Preserve the compiled legacy index, but never carry stale JSON into a new package.
  for (const file of readdirSync(directory)) if (file.endsWith(".json")) rmSync(`${directory}/${file}`);
  for (const [name, contents] of idls)
    if (directory !== "svm/idl" || publicIdlNames.includes(name)) writeFileSync(`${directory}/${name}.json`, contents);
}
