// This script reclaims rent_fund debt to the depositor of the sponsored CCTP bridge.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSponsoredCctpSrcPeripheryProgram, readProgramEvents } from "../../../src/svm/web3-v1";
import { PublicKey, Transaction } from "@solana/web3.js";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;

// Parse arguments
const argvPromise = yargs(hideBin(process.argv)).option("recipient", {
  type: "string",
  demandOption: false,
  describe: "Depositor address to repay rent_fund debt, defaults to signer",
}).argv;

async function repayRentFundDebt(): Promise<void> {
  const argv = await argvPromise;

  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  const recipient = new PublicKey(argv.recipient || txPayer.publicKey.toString());

  const [rentFund] = PublicKey.findProgramAddressSync([Buffer.from("rent_fund")], programId);
  const [rentClaim] = PublicKey.findProgramAddressSync([Buffer.from("rent_claim"), recipient.toBuffer()], programId);

  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "recipient", Value: recipient.toString() },
    { Property: "rentFund", Value: rentFund.toString() },
    { Property: "rentClaim", Value: rentClaim.toString() },
    { Property: "txPayer", Value: txPayer.publicKey.toString() },
  ]);

  const ix = await program.methods.repayRentFundDebt().accounts({ recipient, program: programId }).instruction();

  console.log("Reclaiming rent_fund debt to the depositor...");
  const tx = new Transaction().add(ix);
  const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
  console.log("Repaid debt from rent fund successfully, transaction signature:", txSignature);
}

repayRentFundDebt();
