// This script closes all Relayer PDAs associated with tracking fill Status. Relayers should do this periodically to
// reclaim the lamports within these tracking accounts. Fill Status PDAs can be closed on the deposit has expired.
import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { calculateRelayEventHashUint8Array, readProgramEvents } from "../../src/svm";
import { SvmSpokeAnchor, SvmSpokeIdl } from "../../src/svm/assets";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = new Program<SvmSpokeAnchor>(SvmSpokeIdl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("relayer", { type: "string", demandOption: true, describe: "Relayer public key" }).argv;

async function closeExpiredRelays(): Promise<void> {
  const resolvedArgv = await argv;
  const relayer = new PublicKey(resolvedArgv.relayer);
  const seed = new BN(resolvedArgv.seed);

  console.table([
    { Property: "relayer", Value: relayer.toString() },
    { Property: "seed", Value: seed.toString() },
    { Property: "programId", Value: programId.toString() },
  ]);

  try {
    const events = await readProgramEvents(provider.connection, program);
    const fillEvents = events.filter(
      (event) => event.name === "filledV3Relay" && new PublicKey(event.data.relayer).equals(relayer)
    );

    console.log(`Number of fill events found: ${fillEvents.length}`);

    if (fillEvents.length === 0) {
      console.log("No fill events found for the given relayer.");
      return;
    }

    for (const event of fillEvents) {
      const currentTime = Math.floor(Date.now() / 1000);
      if (currentTime > event.data.fillDeadline) {
        await closeFillPda(event.data, seed);
      } else {
        console.log(
          `Found relay with depositId: ${event.data.depositId} from source chain id: ${event.data.originChainId}, but it is not expired yet.`
        );
      }
    }
  } catch (error) {
    console.error("An error occurred while fetching the fill events:", error);
  }
}

async function closeFillPda(eventData: any, seed: BN): Promise<void> {
  // Accept seed as a parameter
  const relayEventData = {
    depositor: new PublicKey(eventData.depositor),
    recipient: new PublicKey(eventData.recipient),
    exclusiveRelayer: new PublicKey(eventData.exclusiveRelayer),
    inputToken: new PublicKey(eventData.inputToken),
    outputToken: new PublicKey(eventData.outputToken),
    inputAmount: new BN(eventData.inputAmount),
    outputAmount: new BN(eventData.outputAmount),
    originChainId: new BN(eventData.originChainId),
    depositId: eventData.depositId,
    fillDeadline: eventData.fillDeadline,
    exclusivityDeadline: eventData.exclusivityDeadline,
    messageHash: eventData.messageHash,
  };

  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Fetch the state to get the chainId
  const state = await program.account.state.fetch(statePda);
  const chainId = new BN(state.chainId);

  const relayHashUint8Array = calculateRelayEventHashUint8Array(relayEventData, chainId);

  const [fillStatusPda] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], programId);

  try {
    // Check if the fillStatusPda account exists
    const accountInfo = await provider.connection.getAccountInfo(fillStatusPda);
    if (!accountInfo) {
      console.log(
        `Fill Status PDA for depositId: ${eventData.depositId} from source chain id: ${eventData.originChainId} is already closed or does not exist.`
      );
      return;
    }
    // Display additional information in a table
    console.log("Found a relay to close. Relay event data:");
    console.table(
      Object.entries(relayEventData).map(([key, value]) => ({
        key,
        value: value.toString(),
      }))
    );
    console.table([
      { Property: "State PDA", Value: statePda.toString() },
      { Property: "Fill Status PDA", Value: fillStatusPda.toString() },
      { Property: "Relay Hash", Value: Buffer.from(relayHashUint8Array).toString("hex") },
    ]);

    const tx = await (program.methods.closeFillPda() as any)
      .accounts({
        state: statePda,
        signer: provider.wallet.publicKey,
        fillStatus: fillStatusPda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    console.log("Transaction signature:", tx);
  } catch (error) {
    console.error("An error occurred while closing the fill PDA:", error);
  }
}

// Run the closeExpiredRelays function
closeExpiredRelays();
