// This script finds the fillStatus (fillStatus + event) from a provided fillStatusPda.
import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program } from "@coral-xyz/anchor";
import { address, createSolanaRpc } from "@solana/web3-v2.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { SvmSpokeIdl } from "../../src/svm";

import { readFillEventFromFillStatusPda } from "../../src/svm/web3-v2/solanaProgramUtils";
import { program } from "@coral-xyz/anchor/dist/cjs/native/system";
import { SvmSpoke } from "../../target/types/svm_spoke";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);

const argv = yargs(hideBin(process.argv))
  .option("fillStatusPda", { type: "string", demandOption: true, describe: "Fill Status PDA" })
  .option("programId", { type: "string", demandOption: true, describe: "SvmSpoke ID" }).argv;

async function findFillStatusFromFillStatusPda(): Promise<void> {
  const resolvedArgv = await argv;
  const fillStatusPda = address(resolvedArgv.fillStatusPda);

  console.log(`Looking for Fill Event for Fill Status PDA: ${fillStatusPda.toString()}`);

  const rpc = createSolanaRpc(provider.connection.rpcEndpoint);
  const { event, slot } = await readFillEventFromFillStatusPda(
    rpc,
    fillStatusPda,
    address(resolvedArgv.programId),
    SvmSpokeIdl
  );
  if (!event) {
    console.log("No fill events found");
    return;
  }

  console.table(
    Object.entries(event.data).map(([key, value]) => {
      if (key === "relay_execution_info") {
        const info = value as any;
        return { Property: key, Value: `relayer: ${info.relayer}, executionTimestamp: ${info.executionTimestamp}` };
      }
      return { Property: key, Value: (value as any).toString() };
    })
  );

  const program = anchor.workspace.SvmSpoke as Program<SvmSpoke>;
  let fillStatus;
  try {
    const fillStatusResponse = await program.account.fillStatusAccount.fetch(fillStatusPda);
    fillStatus = Object.keys(fillStatusResponse.status)[0];
  } catch (error) {
    fillStatus = "filled";
  }

  console.log("fillStatus", fillStatus);
  console.log("slot", slot);
}

findFillStatusFromFillStatusPda();
