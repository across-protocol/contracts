import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { evmAddressToPublicKey } from "../../src/SvmUtils";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
// const program = new Program<SvmSpoke>(idl, provider);
// const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("initNumbDeposits", { type: "string", demandOption: true, describe: "Init numb of deposits" })
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" })
  .option("remoteDomain", { type: "number", demandOption: true, describe: "CCTP domain for Mainnet Ethereum" })
  .option("crossDomainAdmin", { type: "string", demandOption: true, describe: "HubPool on Mainnet Ethereum" })
  .option("depositQuoteTimeBuffer", {
    type: "number",
    demandOption: false,
    default: 3600,
    describe: "Deposit quote time buffer",
  })
  .option("fillDeadlineBuffer", {
    type: "number",
    demandOption: false,
    default: 3600 * 4,
    describe: "Fill deadline buffer",
  }).argv;

async function initialize(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const initialNumberOfDeposits = resolvedArgv.initNumbDeposits;
  const chainId = new BN(resolvedArgv.chainId);
  const remoteDomain = resolvedArgv.remoteDomain;
  const crossDomainAdmin = evmAddressToPublicKey(resolvedArgv.crossDomainAdmin); // Use the function to cast the value
  const testableMode = false; // Hardcode testableMode to false
  const depositQuoteTimeBuffer = resolvedArgv.depositQuoteTimeBuffer;
  const fillDeadlineBuffer = resolvedArgv.fillDeadlineBuffer;

  // Define the state account PDA
  console.log("Seed:", seed.toString());
  console.log("seed.toArrayLike(Buffer", seed.toArrayLike(Buffer, "le", 8));
  // const [statePda, _] = PublicKey.findProgramAddressSync(
  //   [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
  //   programId
  // );

  // // Define the signer (replace with your actual signer)
  // const signer = provider.wallet.publicKey;

  // console.log("Initializing...");
  // console.table([
  //   { Property: "seed", Value: seed.toString() },
  //   { Property: "initialNumberOfDeposits", Value: initialNumberOfDeposits.toString() },
  //   { Property: "programId", Value: programId.toString() },
  //   { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
  //   { Property: "statePda", Value: statePda.toString() },
  //   { Property: "chainId", Value: chainId.toString() },
  //   { Property: "remoteDomain", Value: remoteDomain.toString() },
  //   { Property: "crossDomainAdmin", Value: crossDomainAdmin.toString() },
  //   { Property: "testableMode", Value: testableMode.toString() },
  //   { Property: "depositQuoteTimeBuffer", Value: depositQuoteTimeBuffer.toString() },
  //   { Property: "fillDeadlineBuffer", Value: fillDeadlineBuffer.toString() },
  // ]);

  // const tx = await (
  //   program.methods.initialize(
  //     seed,
  //     initialNumberOfDeposits,
  //     chainId,
  //     remoteDomain,
  //     crossDomainAdmin,
  //     testableMode,
  //     depositQuoteTimeBuffer,
  //     fillDeadlineBuffer
  //   ) as any
  // )
  //   .accounts({
  //     state: statePda,
  //     signer: signer,
  //     systemProgram: SystemProgram.programId,
  //   })
  //   .rpc();

  // console.log("Transaction signature:", tx);
}

// Run the initialize function
initialize();
