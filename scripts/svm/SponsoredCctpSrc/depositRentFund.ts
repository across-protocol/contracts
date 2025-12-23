// This script deposits SOL to the SVM Sponsored CCTP bridge rent fund.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram, Transaction } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSponsoredCctpSrcPeripheryProgram } from "../../../src/svm/web3-v1";

// Set up the provider and program
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("amount", {
  type: "number",
  demandOption: true,
  describe: "Amount to deposit in lamports",
}).argv;

async function depositRentFund(): Promise<void> {
  const resolvedArgv = await argv;
  const amount = resolvedArgv.amount;

  const [rentFund] = PublicKey.findProgramAddressSync([Buffer.from("rent_fund")], program.programId);

  const txSigner = provider.wallet.publicKey;
  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  console.log("Depositing to the rent fund account...");
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "amount", Value: amount.toString() },
    { Property: "rentFund", Value: rentFund.toString() },
    { Property: "txSigner", Value: txSigner.toString() },
  ]);

  const ix = SystemProgram.transfer({
    fromPubkey: txSigner,
    toPubkey: rentFund,
    lamports: amount,
  });

  const tx = new Transaction().add(ix);
  const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
  console.log("Deposited to the rent fund successfully, transaction signature:", txSignature);
}

depositRentFund();
