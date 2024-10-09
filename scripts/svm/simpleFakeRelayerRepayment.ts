import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram, Keypair } from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  createAssociatedTokenAccount,
} from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import {
  relayerRefundHashFn,
  RelayerRefundLeafType,
  RelayerRefundLeafSolana,
  loadExecuteRelayerRefundLeafParams,
} from "../../test/svm/utils";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("amounts", { type: "array", demandOption: true, describe: "Array of amounts for repayment leaves" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Mint address of the existing token" }).argv;

async function testBundleLogic(): Promise<void> {
  console.log("Fake Relayer Repayment...");
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const amounts = (resolvedArgv.amounts as string[]).map((amount) => new BN(amount));
  const inputToken = new PublicKey(resolvedArgv.inputToken);

  const signer = provider.wallet.publicKey;
  console.log("Running from signer: ", signer.toString());

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
    { property: "amounts", value: amounts },
    { property: "inputToken", value: inputToken.toString() },
    { property: "signer", value: signer.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "routePda", value: routePda.toString() },
    { property: "vault", value: vault.toString() },
  ]);

  // Use program.methods.depositV3 to send tokens to the spoke. note this is NOT a valid deposit, we just want to
  // seed tokens into the spoke to test repayment.
  const depositTx = await (
    program.methods.depositV3(
      signer,
      signer, // recipient is the signer for this example
      inputToken,
      inputToken, // Re-use inputToken as outputToken. does not matter for this deposit.
      amounts.reduce((acc, amount) => acc.add(amount), new BN(0)),
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
      signer: signer,
      userTokenAccount: getAssociatedTokenAddressSync(inputToken, signer),
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: inputToken,
    })
    .rpc();
  console.log(`Deposit transaction sent: ${depositTx}`);

  // Create a single repayment leaf with the array of amounts and corresponding refund accounts
  const refundAccounts: PublicKey[] = [];
  for (let i = 0; i < amounts.length; i++) {
    const recipient = Keypair.generate();
    const refundAccount = await createAssociatedTokenAccount(
      provider.connection,
      (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer,
      inputToken,
      recipient.publicKey
    );
    refundAccounts.push(refundAccount);
    console.log(`Created refund account for recipient ${i + 1}: ${refundAccount.toBase58()}`);
  }

  const relayerRefundLeaf: RelayerRefundLeafType = {
    isSolana: true,
    leafId: new BN(0), // Single leaf
    chainId: new BN(1),
    amountToReturn: new BN(0),
    mintPublicKey: inputToken,
    refundAccounts: refundAccounts, // Array of refund accounts
    refundAmounts: amounts, // Array of amounts
  };

  const merkleTree = new MerkleTree<RelayerRefundLeafType>([relayerRefundLeaf], relayerRefundHashFn);
  const root = merkleTree.getRoot();

  console.log("Merkle Tree Generation. Root: ", Buffer.from(root).toString("hex"));

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
    { property: "Signer", value: signer.toString() },
  ]);

  const relayRootBundleTx = await (program.methods.relayRootBundle(Array.from(root), Array.from(root)) as any)
    .accounts({
      state: statePda,
      rootBundle: rootBundle,
      signer: signer,
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
  await loadExecuteRelayerRefundLeafParams(program, signer, rootBundleId, leaf, proofAsNumbers);

  console.log("loaded execute relayer refund leaf params. Executing relayer refund leaf...");

  const executeRelayerRefundLeafTx = await (program.methods.executeRelayerRefundLeaf() as any)
    .accounts({
      state: statePda,
      rootBundle: rootBundle,
      signer: signer,
      vault: getAssociatedTokenAddressSync(inputToken, statePda, true),
      mint: inputToken,
      transferLiability: transferLiability, // Use the derived PDA
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .remainingAccounts(refundAccounts.map((account) => ({ pubkey: account, isWritable: true, isSigner: false })))
    .rpc();
  console.log(`Execute relayer refund leaf transaction sent: ${executeRelayerRefundLeafTx}`);

  // Check that the relayers got back the amount you were expecting
  for (let i = 0; i < refundAccounts.length; i++) {
    const balance = await provider.connection.getTokenAccountBalance(refundAccounts[i]);
    console.log(`Relayer ${i + 1} received: ${balance.value.amount} tokens`);
  }
}

// Run the testBundleLogic function
testBundleLogic().catch(console.error);
