// This script finds the fillStatus (fillStatus + event) from a provided fillStatusPda.
import { AnchorProvider, BN, Program } from "@anchor-lang/core";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { SvmSpokeIdl, SvmSpokeAnchor } from "../../src/svm/assets";
import { stringifyCpiEvent } from "../../src/svm/web3-v1";
import { readFillEventFromFillStatusPda } from "./utils/events";

export async function inspectFillStatus(
  program: Program<SvmSpokeAnchor>,
  fillStatusPda: PublicKey,
  seed: BN
): Promise<void> {
  const account = await program.account.fillStatusAccount.fetchNullable(fillStatusPda, "confirmed");
  // Report current state even if history is unavailable. Absence alone does not prove a historical fill.
  console.log("fillStatus", account ? Object.keys(account.status)[0] : "account not found");
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    program.programId
  );
  const { chainId } = await program.account.state.fetch(statePda, "confirmed");
  console.log(`Looking for Fill Event for Fill Status PDA: ${fillStatusPda.toBase58()}`);
  const event = await readFillEventFromFillStatusPda(program.provider.connection, program, fillStatusPda, chainId);
  if (!event) {
    console.log("No matching fill event found in available history.");
    return;
  }

  console.log(JSON.stringify(stringifyCpiEvent(event.data, event.name), null, 2));
  if (!account) console.log("Historical fill found; fill-status account has since been closed.");
  console.log("signature", event.signature);
  console.log("slot", event.slot);
}

async function main(): Promise<void> {
  const argv = await yargs(hideBin(process.argv))
    .option("fillStatusPda", { type: "string", demandOption: true, describe: "Fill Status PDA" })
    .option("programId", { type: "string", demandOption: true, describe: "SvmSpoke ID" })
    .option("seed", { type: "string", default: "0", describe: "Seed for the state account PDA" }).argv;
  const program = new Program<SvmSpokeAnchor>(
    { ...SvmSpokeIdl, address: new PublicKey(argv.programId).toBase58() },
    AnchorProvider.env()
  );
  await inspectFillStatus(program, new PublicKey(argv.fillStatusPda), new BN(argv.seed));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
