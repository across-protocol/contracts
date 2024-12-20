// This script queries the state of a given spoke pool.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram } from "../../src/svm";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("seed", {
  type: "string",
  demandOption: true,
  describe: "Seed for the state account PDA",
}).argv;

async function queryState(): Promise<void> {
  const resolvedArgv = await argv;

  const seed = new BN(resolvedArgv.seed);

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  console.log("Querying state...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "programId", Value: programId.toString() },
    { Property: "statePda", Value: statePda.toString() },
  ]);

  try {
    const state = await program.account.state.fetch(statePda);
    console.log("State fetched successfully:");
    console.table([
      { Property: "Owner", Value: state.owner.toString() },
      { Property: "Deposits Paused", Value: state.pausedDeposits },
      { Property: "Fills Paused", Value: state.pausedFills },
      { Property: "Number of Deposits", Value: state.numberOfDeposits.toString() },
      { Property: "Chain ID", Value: state.chainId.toString() },
      { Property: "Current Time", Value: state.currentTime.toString() },
      { Property: "Remote Domain", Value: state.remoteDomain.toString() },
      { Property: "Cross Domain Admin", Value: state.crossDomainAdmin.toString() },
      { Property: "Root Bundle ID", Value: state.rootBundleId.toString() },
      { Property: "Deposit Quote Time Buffer", Value: state.depositQuoteTimeBuffer.toString() },
      { Property: "Fill Deadline Buffer", Value: state.fillDeadlineBuffer.toString() },
    ]);
  } catch (error) {
    console.error("An error occurred while fetching the state:", error);
  }
}

// Run the queryState function
queryState();
