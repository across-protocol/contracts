import { mkdirSync, rmSync, writeFileSync } from "fs";
import { publicIdlNames, readProductionIdls } from "./productionIdls";

const idls = readProductionIdls("src/svm/assets/idl");
// Validate every input before replacing public output. Internal Anchor/Circle assets stay in src/target.
rmSync("svm/idl", { recursive: true, force: true });
rmSync("dist/src/svm", { recursive: true, force: true });
mkdirSync("svm/idl", { recursive: true });
for (const name of publicIdlNames) writeFileSync(`svm/idl/${name}.json`, idls.get(name)!);
