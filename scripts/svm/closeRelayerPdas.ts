// Reclaim expired fill-status rent to the recorded V5 payer PDA or legacy relayer/slow-fill requester.
import { AnchorProvider, BN } from "@anchor-lang/core";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram } from "../../src/svm/web3-v1";

type CleanupTarget = { submitter: PublicKey } | { relayer: PublicKey };

export async function closeExpiredFillStatuses(
  program: ReturnType<typeof getSpokePoolProgram>,
  state: PublicKey,
  target: CleanupTarget,
  currentTime: number
): Promise<number> {
  const rentRecipient =
    "submitter" in target
      ? PublicKey.findProgramAddressSync(
          [Buffer.from("v5_fill_payer"), target.submitter.toBuffer()],
          program.programId
        )[0]
      : target.relayer;
  // Anchor adds the FillStatusAccount discriminator filter. The recipient follows the 8-byte discriminator
  // and 1-byte status; the full account is 45 bytes. Do not filter status: legacy requests also hold rent.
  const statuses = await program.account.fillStatusAccount.all([
    { dataSize: 45 },
    { memcmp: { offset: 9, bytes: rentRecipient.toBase58() } },
  ]);
  console.log(`Found ${statuses.length} fill-status accounts for rent recipient ${rentRecipient.toBase58()}.`);

  let closed = 0;
  let failed = 0;
  for (const { publicKey: fillStatus, account } of statuses) {
    if (currentTime <= account.fillDeadline) continue;
    try {
      const tx = await program.methods
        .closeFillPda()
        .accountsPartial({ state, rentRecipient: account.rentRecipient, fillStatus })
        .rpc({ commitment: "confirmed", preflightCommitment: "confirmed" });
      console.log(`Closed ${fillStatus.toBase58()}: ${tx}`);
      closed++;
    } catch (error) {
      // Another permissionless caller may have closed the account since discovery.
      if ((await program.account.fillStatusAccount.fetchNullable(fillStatus, "confirmed")) === null) continue;
      console.error(`Failed to close ${fillStatus.toBase58()}:`, error);
      failed++;
    }
  }
  if (failed > 0) throw new Error(`Failed to close ${failed} fill-status accounts; ${closed} closed successfully.`);
  return closed;
}

async function main(): Promise<void> {
  const argv = await yargs(hideBin(process.argv))
    .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
    .option("submitter", { type: "string", describe: "V5 fill submitter public key (not the repayment address)" })
    .option("relayer", { type: "string", describe: "Legacy relayer or slow-fill requester public key" })
    .conflicts("submitter", "relayer")
    .check((args) => {
      if (!args.submitter && !args.relayer) throw new Error("Supply --submitter (V5) or --relayer (legacy).");
      return true;
    }).argv;
  const provider = AnchorProvider.env();
  const program = getSpokePoolProgram(provider);
  const [state] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), new BN(argv.seed).toArrayLike(Buffer, "le", 8)],
    program.programId
  );
  const target = argv.submitter
    ? { submitter: new PublicKey(argv.submitter) }
    : { relayer: new PublicKey(argv.relayer!) };
  const currentTime = await provider.connection.getBlockTime(await provider.connection.getSlot("confirmed"));
  if (currentTime === null) throw new Error("RPC did not return the confirmed block time.");
  const closed = await closeExpiredFillStatuses(program, state, target, currentTime);
  console.log(`Closed ${closed} expired fill-status accounts.`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
