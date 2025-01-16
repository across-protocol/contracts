import { clientsPath } from "./generate-svm-clients";

const fs = require("fs");
const path = require("path");

function replaceInFiles(dir: string): void {
  const files = fs.readdirSync(dir);
  files.forEach((file: string) => {
    const filePath = path.join(dir, file);
    const stat = fs.statSync(filePath);

    if (stat.isDirectory()) {
      replaceInFiles(filePath);
    } else if (file.endsWith(".ts")) {
      const fileContent = fs.readFileSync(filePath, "utf8");
      const updatedContent = fileContent.replace("@solana/web3.js", "@solana/web3-v2.js");
      fs.writeFileSync(filePath, updatedContent);
    }
  });
}

replaceInFiles(clientsPath);
