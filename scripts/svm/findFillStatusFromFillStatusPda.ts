// This script finds the fillStatus (fillStatus + event) from a provided fillStatusPda.
import { AnchorProvider, Program } from "@anchor-lang/core";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { SvmSpokeIdl, SvmSpokeAnchor } from "../../src/svm/assets";
import { stringifyCpiEvent } from "../../src/svm/web3-v1";
import { readFillEventFromFillStatusPda } from "./utils/events";

const provider = AnchorProvider.env();

const argv = yargs(hideBin(process.argv))
  .option("fillStatusPda", { type: "string", demandOption: true, describe: "Fill Status PDA" })
  .option("programId", { type: "string", demandOption: true, describe: "SvmSpoke ID" }).argv;

async function findFillStatusFromFillStatusPda(): Promise<void> {
  const resolvedArgv = await argv;
  const fillStatusPda = new PublicKey(resolvedArgv.fillStatusPda);
  const program = new Program<SvmSpokeAnchor>(
    { ...SvmSpokeIdl, address: new PublicKey(resolvedArgv.programId).toBase58() },
    provider
  );
  console.log(`Looking for Fill Event for Fill Status PDA: ${fillStatusPda.toBase58()}`);
  const event = await readFillEventFromFillStatusPda(provider.connection, program, fillStatusPda);
  if (!event) {
    console.log("No fill events found");
    return;
  }

  console.log(JSON.stringify(stringifyCpiEvent(event.data, event.name), null, 2));
  const account = await program.account.fillStatusAccount.fetchNullable(fillStatusPda, "confirmed");
  // Missing accounts can follow rent reclaim; RPC/decoding failures must still propagate.
  console.log("fillStatus", account ? Object.keys(account.status)[0] : "closed (historical fill)");
  console.log("slot", event.slot);
}

findFillStatusFromFillStatusPda().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
