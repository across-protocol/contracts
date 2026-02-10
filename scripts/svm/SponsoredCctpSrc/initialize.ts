// This script initializes a SVM Sponsored CCTP bridge with initialization parameters.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, Transaction } from "@solana/web3.js";
import bs58 from "bs58";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { evmAddressToPublicKey, getSponsoredCctpSrcPeripheryProgram } from "../../../src/svm/web3-v1";

// Set up the provider and program
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("sourceDomain", { type: "number", demandOption: false, default: 5, describe: "CCTP domain for Solana" })
  .option("quoteSigner", {
    type: "string",
    demandOption: true,
    describe: "Sponsored deposit quote signer, EVM address",
  }).argv;

async function initialize(): Promise<void> {
  const resolvedArgv = await argv;
  const sourceDomain = resolvedArgv.sourceDomain;
  const quoteSigner = evmAddressToPublicKey(resolvedArgv.quoteSigner);

  const txSigner = provider.wallet.publicKey;
  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  const [programData] = PublicKey.findProgramAddressSync(
    [program.programId.toBuffer()],
    new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111")
  );
  const upgradeAuthority = await (async () => {
    const { value } = await provider.connection.getParsedAccountInfo(programData);
    const authority = value?.data && !Buffer.isBuffer(value?.data) ? value?.data.parsed?.info?.authority : undefined;
    if (authority) return new PublicKey(authority);
    throw new Error("Could not get parsed program data account");
  })();
  const [state] = PublicKey.findProgramAddressSync([Buffer.from("state")], program.programId);

  console.log("Initializing...");
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "sourceDomain", Value: sourceDomain.toString() },
    { Property: "quoteSigner", Value: quoteSigner.toString() },
    { Property: "txSigner", Value: txSigner.toString() },
    { Property: "upgradeAuthority", Value: upgradeAuthority.toString() },
    { Property: "programData", Value: programData.toString() },
    { Property: "state", Value: state.toString() },
  ]);

  const ix = await program.methods
    .initialize({ sourceDomain, signer: quoteSigner })
    .accounts({
      signer: upgradeAuthority,
      programData,
    })
    .instruction();

  if (txSigner.equals(upgradeAuthority)) {
    console.log("Signer is the upgrade authority, initializing the program...");
    const tx = new Transaction().add(ix);
    const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
    console.log("Program initialized successfully, transaction signature:", txSignature);
  } else {
    console.log(
      "Signer is not the upgrade authority, can only simulate the transaction or import it into the multi-sig transaction builder."
    );
    const tx = new Transaction({
      feePayer: txSigner,
      blockhash: PublicKey.default.toString(),
      lastValidBlockHeight: 0,
    }).add(ix);

    // Should throw upon simulation error
    await provider.simulate(tx);

    const encodedTx = bs58.encode(Buffer.from(tx.serialize({ requireAllSignatures: false, verifySignatures: false })));
    console.log("Simulation successful, import the base58 encoded transaction:\n", encodedTx);
  }
}

initialize();
