import * as anchor from "@coral-xyz/anchor";
import { IdlV01 } from "@codama/nodes-from-anchor";
import { exec } from "child_process";
import * as fs from "fs";
import * as path from "path";

const RPC_URL = "https://api.devnet.solana.com";

const main = async () => {
  const externalPrograms = [
    { name: "message_transmitter", id: "CCTPmbSD7gX1bxKPAmg77w8oFzNFpaQiQUWD43TKaecd", legacyIdl: true },
    { name: "token_messenger_minter", id: "CCTPiPYPc6AsJuwueEnWgSgucamXDZwBd53dQ11YiKX3", legacyIdl: true },
    { name: "message_transmitter_v2", id: "CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC", legacyIdl: false },
    { name: "token_messenger_minter_v2", id: "CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe", legacyIdl: false },
  ];

  for (const program of externalPrograms) {
    await fetchIdl(program.name, program.id, program.legacyIdl);
    if (program.legacyIdl) await convertIdl(program.name);
    await generateType(program.name);
    await copyIdls(program.name);
  }
};

const fetchIdl = async (programName: string, programId: string, legacyIdl: boolean) => {
  const provider = anchor.AnchorProvider.local(RPC_URL);

  const idl = (await anchor.Program.fetchIdl(programId, provider)) as any;

  // Legacy CCTP programs have missing metadata.address
  if (legacyIdl) idl.metadata = { address: programId };

  if (!legacyIdl) patchIdlV01(idl as IdlV01);

  const idlDir = path.resolve(__dirname, "../../../target/idl");
  const outputFilePath = path.join(idlDir, `${programName}.json`);
  fs.writeFileSync(outputFilePath, JSON.stringify(idl, null, 2));
};

const convertIdl = async (programName: string): Promise<void> => {
  const idlDir = path.resolve(__dirname, "../../../target/idl");
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
  const idlDir = path.resolve(__dirname, "../../../target/idl");
  const idlFilePath = path.join(idlDir, `${programName}.json`);
  const typesDir = path.resolve(__dirname, "../../../target/types");
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
  const idlDir = path.resolve(__dirname, "../../../target/idl");
  const idlsDir = path.resolve(__dirname, "../../../idls");
  const idlFilePath = path.join(idlDir, `${programName}.json`);
  const idlFilePathCopy = path.join(idlsDir, `${programName}.json`);

  if (!fs.existsSync(idlsDir)) fs.mkdirSync(idlsDir, { recursive: true });
  fs.copyFileSync(idlFilePath, idlFilePathCopy);
};

// Codama does not yet support PDAs derived from other user provided programs, hence we patch the IDL by removing such
// `pda` fields to avoid build errors in the generated clients.
const patchIdlV01 = (idl: IdlV01): void => {
  idl.instructions.forEach((instruction) => {
    instruction.accounts.forEach((account) => {
      if ("pda" in account && account.pda?.program?.kind === "account") {
        const programPath = account.pda.program.path;
        const programNode = instruction.accounts.find((acc) => acc.name == programPath);
        if (!(programNode && "address" in programNode)) {
          delete account.pda;
        }
      }
    });
  });
};

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
