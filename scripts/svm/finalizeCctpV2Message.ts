// Finalize an existing EVM -> Solana admin/root message or token transfer. Requires only a funded Solana wallet.
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import "dotenv/config";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { CIRCLE_IRIS_API_URL_DEVNET, CIRCLE_IRIS_API_URL_MAINNET } from "../../src/svm/web3-v1/constants";
import { isSolanaDevnet } from "../../src/svm/web3-v1/helpers";
import { getSpokePoolProgram, getTokenMessengerMinterV2Program } from "../../src/svm/web3-v1/programConnectors";
import { finalizeCctpV2Messages } from "./utils/cctpV2";

async function main() {
  const args = await yargs(hideBin(process.argv))
    .option("sourceTx", { type: "string", demandOption: true, describe: "EVM source transaction hash" })
    .option("seed", { type: "string", default: "0", describe: "Spoke state PDA seed (production: 0)" })
    .option("nonce", { type: "string", describe: "Only finalize this attested nonce (decimal or 0x hex)" })
    .option("sourceDomain", { type: "number", describe: "CCTP source domain (defaults to spoke remote domain)" })
    .option("tokenRecipient", {
      type: "string",
      describe: "Expected destination token account (defaults to spoke vault ATA)",
    })
    .option("timeoutSeconds", { type: "number", default: 120, describe: "Attestation polling timeout" })
    .strict()
    .parse();
  const provider = AnchorProvider.env();
  const program = getSpokePoolProgram(provider);
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), new BN(args.seed).toArrayLike(Buffer, "le", 8)],
    program.programId
  );
  const sourceDomain = args.sourceDomain ?? (await program.account.state.fetch(statePda)).remoteDomain;
  await finalizeCctpV2Messages(
    provider,
    program,
    statePda,
    args.sourceTx,
    sourceDomain,
    isSolanaDevnet(provider) ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET,
    args.timeoutSeconds * 1000,
    args.nonce,
    {
      program: getTokenMessengerMinterV2Program(provider),
      expectedRecipient: args.tokenRecipient ? new PublicKey(args.tokenRecipient) : undefined,
    }
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
