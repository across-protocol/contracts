import * as anchor from "@coral-xyz/anchor";
import { exec } from "child_process";
import * as fs from "fs";
import * as path from "path";

const RPC_URL = "https://api.devnet.solana.com";

const main = async () => {
  const externalPrograms = [
    { name: "message_transmitter", id: "CCTPmbSD7gX1bxKPAmg77w8oFzNFpaQiQUWD43TKaecd" },
    { name: "token_messenger_minter", id: "CCTPiPYPc6AsJuwueEnWgSgucamXDZwBd53dQ11YiKX3" },
  ];

  for (const program of externalPrograms) {
    await fetchIdl(program.name, program.id);
    await convertIdl(program.name);
    await generateType(program.name);
    await copyIdls(program.name);
  }
};

const fetchIdl = async (programName: string, programId: string) => {
  const provider = anchor.AnchorProvider.local(RPC_URL);

  const idl = (await anchor.Program.fetchIdl(programId, provider)) as any;

  // CCTP programs have missing metadata.address
  idl.metadata = { address: programId };

  const idlDir = path.resolve(__dirname, "../../target/idl");
  const outputFilePath = path.join(idlDir, `${programName}.json`);
  fs.writeFileSync(outputFilePath, JSON.stringify(idl, null, 2));
};

const convertIdl = async (programName: string): Promise<void> => {
  const idlDir = path.resolve(__dirname, "../../target/idl");
  const idlFilePath = path.join(idlDir, `${programName}.json`);

  return new Promise((resolve, reject) => {
    exec(`anchor idl convert --out ${idlFilePath} ${idlFilePath}`, (err, _stdout, stderr) => {
      if (stderr) {
        console.error(`${stderr}`);
      }
      if (err) {
        reject(new Error(`Failed to convert ${programName} IDL`));
      } else {
        resolve();
      }
    });
  });
};

const generateType = async (programName: string): Promise<void> => {
  const idlDir = path.resolve(__dirname, "../../target/idl");
  const idlFilePath = path.join(idlDir, `${programName}.json`);
  const typesDir = path.resolve(__dirname, "../../target/types");
  const typeFilePath = path.join(typesDir, `${programName}.ts`);

  return new Promise((resolve, reject) => {
    exec(`anchor idl type --out "${typeFilePath}" "${idlFilePath}"`, (err, _stdout, stderr) => {
      if (stderr) {
        console.error(`${stderr}`);
      }
      if (err) {
        reject(new Error(`Failed to generate type for ${programName}`));
      } else {
        resolve();
      }
    });
  });
};

const copyIdls = async (programName: string): Promise<void> => {
  const idlDir = path.resolve(__dirname, "../../target/idl");
  const idlsDir = path.resolve(__dirname, "../../idls");
  const idlFilePath = path.join(idlDir, `${programName}.json`);
  const idlFilePathCopy = path.join(idlsDir, `${programName}.json`);

  if (!fs.existsSync(idlsDir)) fs.mkdirSync(idlsDir, { recursive: true });
  fs.copyFileSync(idlFilePath, idlFilePathCopy);
};

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
