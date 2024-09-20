import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("seed", {
  type: "string",
  demandOption: true,
  describe: "Seed for the state account PDA",
}).argv;

const seed = new BN(argv.seed);

// Define the state account PDA
const [statePda, _] = PublicKey.findProgramAddressSync(
  [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
  programId
);

async function queryState(): Promise<void> {
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
      { Property: "Deposits Enabled", Value: !state.pausedDeposits },
      { Property: "Number of Deposits", Value: state.numberOfDeposits.toString() },
      { Property: "Chain ID", Value: state.chainId.toString() }, // Added chainId
    ]);
  } catch (error) {
    console.error("An error occurred while fetching the state:", error);
  }
}

// Run the queryState function
queryState();
