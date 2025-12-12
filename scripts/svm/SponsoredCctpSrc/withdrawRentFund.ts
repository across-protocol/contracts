// This script withdraws from a SVM Sponsored CCTP bridge rent fund.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey, Transaction } from "@solana/web3.js";
import bs58 from "bs58";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSponsoredCctpSrcPeripheryProgram } from "../../../src/svm/web3-v1";

// Set up the provider and program
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("recipient", {
    type: "string",
    demandOption: false,
    describe: "Recipient of the withdrawn funds, defaults to upgrade authority",
  })
  .option("amount", {
    type: "number",
    demandOption: false,
    describe: "Amount to withdraw in lamports, defaults to all balance",
  }).argv;

async function withdrawRentFund(): Promise<void> {
  const resolvedArgv = await argv;

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
  const [rentFund] = PublicKey.findProgramAddressSync([Buffer.from("rent_fund")], program.programId);

  const rentFundBalance = await provider.connection.getBalance(rentFund);

  const recipient = new PublicKey(resolvedArgv.recipient || upgradeAuthority.toString());
  const amount = new BN(resolvedArgv.amount || rentFundBalance);

  const txSigner = provider.wallet.publicKey;
  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  console.log("Withdrawing from rent fund account...");
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "recipient", Value: recipient.toString() },
    { Property: "amount", Value: amount.toString() },
    { Property: "rentFund", Value: rentFund.toString() },
    { Property: "txSigner", Value: txSigner.toString() },
    { Property: "upgradeAuthority", Value: upgradeAuthority.toString() },
    { Property: "programData", Value: programData.toString() },
    { Property: "state", Value: state.toString() },
  ]);

  const ix = await program.methods
    .withdrawRentFund({ amount })
    .accounts({
      signer: upgradeAuthority,
      recipient,
      programData,
    })
    .instruction();

  if (txSigner.equals(upgradeAuthority)) {
    console.log("Signer is the upgrade authority, withdrawing from rent fund...");
    const tx = new Transaction().add(ix);
    const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
    console.log("Withdrawn from rent fund successfully, transaction signature:", txSignature);
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

    const encodedTx = bs58.encode(tx.serialize({ requireAllSignatures: false, verifySignatures: false }));
    console.log("Simulation successful, import the base58 encoded transaction:\n", encodedTx);
  }
}

withdrawRentFund();
