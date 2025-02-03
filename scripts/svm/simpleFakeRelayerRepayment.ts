// This script executes a fake relayer repayment with a generated leaf. Useful for testing.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccount,
  getAssociatedTokenAddressSync,
  getMint,
} from "@solana/spl-token";
import {
  AddressLookupTableProgram,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionMessage,
  VersionedTransaction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram, loadExecuteRelayerRefundLeafParams, relayerRefundHashFn } from "../../src/svm/web3-v1";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../src/types/svm";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("numberOfRelayersToRepay", { type: "string", demandOption: true, describe: "Number of relayers to repay" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Mint address of the existing token" }).argv;

async function testBundleLogic(): Promise<void> {
  console.log("Fake Relayer Repayment...");
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const numberOfRelayersToRepay = parseInt(resolvedArgv.numberOfRelayersToRepay, 10);
  const amounts = Array.from({ length: numberOfRelayersToRepay }, (_, i) => new BN(i + 1));
  const inputToken = new PublicKey(resolvedArgv.inputToken);

  const signer = (provider.wallet as anchor.Wallet).payer;
  console.log("Running from signer: ", signer.publicKey.toString());

  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // This assumes that the destination chain Id 11155111 has been enabled. This is the sepolia chain ID.
  // I.e this test assumes that enableRoute has been called with destinationChainId 11155111 and inputToken.
  const [routePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("route"), inputToken.toBytes(), statePda.toBytes(), new BN(11155111).toArrayLike(Buffer, "le", 8)], // Assuming destinationChainId is 1
    programId
  );

  const vault = getAssociatedTokenAddressSync(
    inputToken,
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  console.table([
    { property: "seed", value: seed.toString() },
    { property: "numberOfRelayersToRepay", value: numberOfRelayersToRepay },
    { property: "inputToken", value: inputToken.toString() },
    { property: "signer", value: signer.publicKey.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "routePda", value: routePda.toString() },
    { property: "vault", value: vault.toString() },
  ]);

  const userTokenAccount = getAssociatedTokenAddressSync(inputToken, signer.publicKey);

  const tokenDecimals = (await getMint(provider.connection, inputToken, undefined, TOKEN_PROGRAM_ID)).decimals;

  // Use program.methods.depositV3 to send tokens to the spoke. note this is NOT a valid deposit, we just want to
  // seed tokens into the spoke to test repayment.

  // Delegate state PDA to pull depositor tokens.
  const inputAmount = amounts.reduce((acc, amount) => acc.add(amount), new BN(0));
  const approveIx = await createApproveCheckedInstruction(
    userTokenAccount,
    inputToken,
    statePda,
    signer.publicKey,
    BigInt(inputAmount.toString()),
    tokenDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );
  const depositIx = await (
    program.methods.depositV3(
      signer.publicKey,
      signer.publicKey, // recipient is the signer for this example
      inputToken,
      inputToken, // Re-use inputToken as outputToken. does not matter for this deposit.
      inputAmount,
      new BN(0),
      new BN(11155111), // destinationChainId. assumed to be enabled, as with routePDA
      PublicKey.default, // exclusiveRelayer
      Math.floor(Date.now() / 1000) - 1, // quoteTimestamp
      Math.floor(Date.now() / 1000) + 3600, // fillDeadline
      0, // exclusivityDeadline
      Buffer.from([]) // message
    ) as any
  )
    .accounts({
      state: statePda,
      route: routePda,
      signer: signer.publicKey,
      userTokenAccount: getAssociatedTokenAddressSync(inputToken, signer.publicKey),
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: inputToken,
    })
    .instruction();
  const depositTx = await sendAndConfirmTransaction(provider.connection, new Transaction().add(approveIx, depositIx), [
    signer,
  ]);

  console.log(`Deposit transaction sent: ${depositTx}`);

  // Create a single repayment leaf with the array of amounts and corresponding refund addresses
  const refundAddresses: PublicKey[] = [];
  const refundAccounts: PublicKey[] = [];
  for (let i = 0; i < amounts.length; i++) {
    const recipient = Keypair.generate();
    const refundAccount = await createAssociatedTokenAccount(
      provider.connection,
      (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer,
      inputToken,
      recipient.publicKey
    );
    refundAddresses.push(recipient.publicKey);
    refundAccounts.push(refundAccount);
    console.log(
      `Created refund account for recipient ${
        i + 1
      }: ${refundAccount.toBase58()}. owner ${recipient.publicKey.toBase58()}`
    );
  }

  console.log("building merkle tree...");
  // Fetch the state account to get the chainId
  const relayerRefundLeaf: RelayerRefundLeafType = {
    isSolana: true,
    leafId: new BN(0), // this is the first and only leaf in the tree.
    chainId: new BN((await program.account.state.fetch(statePda)).chainId), // set chainId to svm spoke chainId.
    amountToReturn: new BN(0),
    mintPublicKey: inputToken,
    refundAddresses, // Array of refund authority addresses
    refundAmounts: amounts, // Array of amounts
  };

  const merkleTree = new MerkleTree<RelayerRefundLeafType>([relayerRefundLeaf], relayerRefundHashFn);
  const root = merkleTree.getRoot();

  console.log("Merkle Tree Generated. Root: ", Buffer.from(root).toString("hex"));

  // Set the tree using the methods from the .Bundle test
  const state = await program.account.state.fetch(statePda); // Fetch the state account
  const rootBundleId = state.rootBundleId;
  const rootBundleIdBuffer = Buffer.alloc(4);
  rootBundleIdBuffer.writeUInt32LE(rootBundleId);
  const seeds = [Buffer.from("root_bundle"), statePda.toBuffer(), rootBundleIdBuffer];
  const [rootBundle] = PublicKey.findProgramAddressSync(seeds, programId);

  console.table([
    { property: "State PDA", value: statePda.toString() },
    { property: "Route PDA", value: routePda.toString() },
    { property: "Root Bundle PDA", value: rootBundle.toString() },
    { property: "Signer", value: signer.publicKey.toString() },
  ]);

  const relayRootBundleTx = await (program.methods.relayRootBundle(Array.from(root), Array.from(root)) as any)
    .accounts({
      state: statePda,
      rootBundle: rootBundle,
      signer: signer.publicKey,
      payer: signer.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc();
  console.log(`Relay root bundle transaction sent: ${relayRootBundleTx}`);

  // Execute the single leaf
  const proof = merkleTree.getProof(relayerRefundLeaf).map((p) => Array.from(p));
  const leaf = relayerRefundLeaf as RelayerRefundLeafSolana;

  // Derive the transferLiability PDA
  const [transferLiability] = PublicKey.findProgramAddressSync(
    [Buffer.from("transfer_liability"), inputToken.toBuffer()],
    program.programId
  );

  // Load the instruction parameters
  const proofAsNumbers = proof.map((p) => Array.from(p));
  console.log("loading execute relayer refund leaf params...");

  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), signer.publicKey.toBuffer()],
    program.programId
  );

  const staticAccounts = {
    instructionParams,
    state: statePda,
    rootBundle: rootBundle,
    signer: signer.publicKey,
    vault: vault,
    tokenProgram: TOKEN_PROGRAM_ID,
    mint: inputToken,
    transferLiability,
    systemProgram: anchor.web3.SystemProgram.programId,
    // Appended by Acnhor `event_cpi` macro:
    eventAuthority: PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId)[0],
    program: program.programId,
  };

  const remainingAccounts = refundAccounts.map((account) => ({ pubkey: account, isWritable: true, isSigner: false }));

  // Consolidate all above addresses into a single array for the  Address Lookup Table (ALT).
  const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
    authority: signer.publicKey,
    payer: signer.publicKey,
    recentSlot: await provider.connection.getSlot(),
  });

  // Submit the ALT creation transaction
  await anchor.web3.sendAndConfirmTransaction(
    provider.connection,
    new anchor.web3.Transaction().add(lookupTableInstruction),
    [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
    { skipPreflight: true }
  );

  const lookupAddresses = [...Object.values(staticAccounts), ...refundAccounts];

  // Create the transaction with the compute budget expansion instruction & use extended ALT account.

  // Extend the ALT with all accounts
  const maxExtendedAccounts = 30; // Maximum number of accounts that can be added to ALT in a single transaction.
  for (let i = 0; i < lookupAddresses.length; i += maxExtendedAccounts) {
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: signer.publicKey,
      payer: signer.publicKey,
      addresses: lookupAddresses.slice(i, i + maxExtendedAccounts),
    });

    await anchor.web3.sendAndConfirmTransaction(
      provider.connection,
      new anchor.web3.Transaction().add(extendInstruction),
      [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
      { skipPreflight: true }
    );
  }
  // Fetch the AddressLookupTableAccount
  const lookupTableAccount = (await provider.connection.getAddressLookupTable(lookupTableAddress)).value;
  if (!lookupTableAccount) {
    throw new Error("AddressLookupTableAccount not fetched");
  }

  await loadExecuteRelayerRefundLeafParams(program, signer.publicKey, rootBundleId, leaf, proofAsNumbers);

  console.log(`loaded execute relayer refund leaf params ${instructionParams}. \nExecuting relayer refund leaf...`);

  const executeInstruction = await program.methods
    .executeRelayerRefundLeaf()
    .accounts(staticAccounts)
    .remainingAccounts(remainingAccounts)
    .instruction();

  // Create the versioned transaction
  const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 500_000 });
  const versionedTx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: signer.publicKey,
      recentBlockhash: (await provider.connection.getLatestBlockhash()).blockhash,
      instructions: [computeBudgetInstruction, executeInstruction],
    }).compileToV0Message([lookupTableAccount])
  );

  // Sign and submit the versioned transaction
  versionedTx.sign([(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer]);
  const tx = await provider.connection.sendTransaction(versionedTx);
  console.log(`Execute relayer refund leaf transaction sent: ${tx}`);

  // Close the instruction parameters account
  console.log("Closing instruction params...");
  await new Promise((resolve) => setTimeout(resolve, 15000)); // Wait for the previous transaction to be processed.
  const closeInstructionParamsTx = await (program.methods.closeInstructionParams() as any)
    .accounts({ signer: signer.publicKey, instructionParams: instructionParams })
    .rpc();
  console.log(`Close instruction params transaction sent: ${closeInstructionParamsTx}`);
  // Note we cant close the lookup table account as it needs to be both deactivated and expired at to do this.

  // Check that the relayers got back the amount you were expecting
  const relayerBalances = [];
  for (let i = 0; i < refundAccounts.length; i++) {
    const balance = await provider.connection.getTokenAccountBalance(refundAccounts[i]);
    relayerBalances.push({ relayer: i + 1, tokensReceived: balance.value.amount });
  }
  console.table(relayerBalances);
}

// Run the testBundleLogic function
testBundleLogic().catch(console.error);
