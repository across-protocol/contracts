import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { BN, Program } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount,
  createTransferCheckedInstruction,
} from "@solana/spl-token";
import {
  PublicKey,
  Keypair,
  AccountMeta,
  TransactionInstruction,
  sendAndConfirmTransaction,
  Transaction,
  ComputeBudgetProgram,
} from "@solana/web3.js";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import {
  calculateRelayHashUint8Array,
  MulticallHandlerCoder,
  AcrossPlusMessageCoder,
  sendTransactionWithLookupTable,
  readEventsUntilFound,
  calculateRelayEventHashUint8Array,
  slowFillHashFn,
  loadRequestSlowFillParams,
  loadExecuteSlowRelayLeafParams,
  intToU8Array32,
} from "../../src/svm/web3-v1";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { common } from "./SvmSpoke.common";
import {
  ExecuteSlowRelayLeafDataParams,
  ExecuteSlowRelayLeafDataValues,
  RequestSlowFillDataParams,
  RequestSlowFillDataValues,
  SlowFillLeaf,
} from "../../src/types/svm";
const { provider, connection, program, owner, chainId, setCurrentTime } = common;
const { initializeState, assertSE, assert } = common;

describe("svm_spoke.slow_fill.across_plus", () => {
  anchor.setProvider(provider);
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const relayer = Keypair.generate();
  const tokenDecimals = 6;

  const handlerProgram = anchor.workspace.MulticallHandler as Program<MulticallHandler>;

  let handlerSigner: PublicKey,
    handlerATA: PublicKey,
    finalRecipient: PublicKey,
    finalRecipientATA: PublicKey,
    state: PublicKey,
    vault: PublicKey,
    mint: PublicKey;

  const relayAmount = 500_000;
  let relayData: SlowFillLeaf["relayData"]; // reused relay data for all tests.
  let requestAccounts: any; // Store accounts to simplify program interactions.
  let seed: BN;

  const seedBalance = 10_000_000_000;

  async function updateRelayData(newRelayData: SlowFillLeaf["relayData"]) {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    // Accounts for requestingSlowFill.
    requestAccounts = {
      signer: relayer.publicKey,
      instructionParams: program.programId,
      state,
      fillStatusPDA,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
  }

  const relaySlowFillRootBundle = async () => {
    const slowRelayLeafs: SlowFillLeaf[] = [];
    const slowRelayLeaf: SlowFillLeaf = {
      relayData,
      chainId,
      updatedOutputAmount: relayData.outputAmount,
    };

    slowRelayLeafs.push(slowRelayLeaf);

    // Generate bunch of other leaves, so that we have large proofs array to test (this gets 4 proofs elements).
    for (let i = 0; i < 15; i++) {
      slowRelayLeafs.push({
        relayData,
        chainId: new BN(Math.random() * 100000),
        updatedOutputAmount: relayData.outputAmount,
      });
    }

    const merkleTree = new MerkleTree<SlowFillLeaf>(slowRelayLeafs, slowFillHashFn);

    const slowRelayRoot = merkleTree.getRoot();
    const proof = merkleTree.getProof(slowRelayLeafs[0]);
    const leaf = slowRelayLeafs[0];

    const stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    const relayerRefundRoot = crypto.randomBytes(32);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(Array.from(relayerRefundRoot), Array.from(slowRelayRoot))
      .accounts(relayRootBundleAccounts)
      .rpc();

    const proofAsNumbers = proof.map((p) => Array.from(p));
    const relayHash = calculateRelayHashUint8Array(slowRelayLeaf.relayData, chainId);

    return { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle };
  };

  const createSlowFillIx = async (multicallHandlerCoder: MulticallHandlerCoder, bufferParams = false) => {
    // Relay root bundle with slow fill leaf.
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle();

    const requestSlowFillValues: RequestSlowFillDataValues = [Array.from(relayHash), leaf.relayData];
    let loadRequestParamsInstructions: TransactionInstruction[] = [];
    if (bufferParams) {
      loadRequestParamsInstructions = await loadRequestSlowFillParams(program, relayer, requestSlowFillValues[1]);
      [requestAccounts.instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
        program.programId
      );
    }
    const requestSlowFillParams: RequestSlowFillDataParams = bufferParams
      ? [requestSlowFillValues[0], null]
      : requestSlowFillValues;
    const requestIx = await program.methods
      .requestSlowFill(...requestSlowFillParams)
      .accounts(requestAccounts)
      .instruction();

    const executeAccounts = {
      state,
      rootBundle,
      signer: relayer.publicKey,
      instructionParams: requestAccounts.instructionParams,
      fillStatus: requestAccounts.fillStatus,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      recipientTokenAccount: handlerATA,
      program: program.programId,
    };
    const executeRemainingAccounts: AccountMeta[] = [
      { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
      ...multicallHandlerCoder.compiledKeyMetas,
    ];
    const executeSlowRelayLeafValues: ExecuteSlowRelayLeafDataValues = [
      Array.from(relayHash),
      leaf,
      rootBundleId,
      proofAsNumbers,
    ];
    let loadExecuteParamsInstructions: TransactionInstruction[] = [];
    if (bufferParams) {
      loadExecuteParamsInstructions = await loadExecuteSlowRelayLeafParams(
        program,
        relayer,
        executeSlowRelayLeafValues[1],
        executeSlowRelayLeafValues[2],
        executeSlowRelayLeafValues[3]
      );
      [requestAccounts.instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
        program.programId
      );
    }
    const executeSlowRelayLeafParams: ExecuteSlowRelayLeafDataParams = bufferParams
      ? [executeSlowRelayLeafValues[0], null, null, null]
      : executeSlowRelayLeafValues;
    const executeIx = await program.methods
      .executeSlowRelayLeaf(...executeSlowRelayLeafParams)
      .accounts(executeAccounts)
      .remainingAccounts(executeRemainingAccounts)
      .instruction();

    return { loadRequestParamsInstructions, requestIx, loadExecuteParamsInstructions, executeIx };
  };

  before("Creates token mint and associated token accounts", async () => {
    mint = await createMint(connection, payer, owner, owner, tokenDecimals);

    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL

    [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);
    handlerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, handlerSigner, true)).address;
  });

  beforeEach(async () => {
    finalRecipient = Keypair.generate().publicKey;
    finalRecipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, finalRecipient)).address;

    ({ state, seed } = await initializeState());
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address; // Initialize vault

    // mint mint to vault
    await mintTo(connection, payer, mint, vault, owner, seedBalance);

    const initialRelayData = {
      depositor: finalRecipient,
      recipient: handlerSigner, // Handler PDA that can forward tokens as needed within the message call.
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: intToU8Array32(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // Unique ID for each test.
      fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
      exclusivityDeadline: Math.floor(Date.now() / 1000) - 30, // Note we set time in past to avoid exclusivity deadline
      message: Buffer.from(""), // Will be populated in the tests below.
    };

    await updateRelayData(initialRelayData);
  });

  it("Forwards tokens to the final recipient within invoked message call", async () => {
    const iVaultBal = (await getAccount(connection, vault)).amount;

    // Construct ix to transfer all tokens from handler to the final recipient.
    const transferIx = createTransferCheckedInstruction(
      handlerATA,
      mint,
      finalRecipientATA,
      handlerSigner,
      relayData.outputAmount.toNumber(),
      tokenDecimals
    );

    const multicallHandlerCoder = new MulticallHandlerCoder([transferIx]);

    const handlerMessage = multicallHandlerCoder.encode();

    const message = new AcrossPlusMessageCoder({
      handler: handlerProgram.programId,
      readOnlyLen: multicallHandlerCoder.readOnlyLen,
      valueAmount: new BN(0),
      accounts: multicallHandlerCoder.compiledMessage.accountKeys,
      handlerMessage,
    });

    const encodedMessage = message.encode();

    // Update relay data with the encoded message.
    const newRelayData = { ...relayData, message: encodedMessage };
    updateRelayData(newRelayData);

    // Request and execute slow fill.
    const { requestIx, executeIx } = await createSlowFillIx(multicallHandlerCoder);
    await sendAndConfirmTransaction(connection, new Transaction().add(requestIx), [relayer]);
    await sendTransactionWithLookupTable(connection, [executeIx], relayer);

    // Verify vault's balance after the fill
    const fVaultBal = (await getAccount(connection, vault)).amount;
    assertSE(fVaultBal, iVaultBal - BigInt(relayAmount), "Vault's balance should be reduced by the relay amount");

    // Verify final recipient's balance after the fill
    const finalRecipientAccount = await getAccount(connection, finalRecipientATA);
    assertSE(
      finalRecipientAccount.amount,
      relayAmount,
      "Final recipient's balance should be increased by the relay amount"
    );
  });

  describe("Max token distributions within invoked message call", async () => {
    const fillTokenDistributions = async (numberOfDistributions: number, bufferParams = false) => {
      const iVaultBal = (await getAccount(connection, vault)).amount;

      const distributionAmount = Math.floor(relayAmount / numberOfDistributions);

      const recipientAccounts: PublicKey[] = [];
      const transferInstructions: TransactionInstruction[] = [];
      for (let i = 0; i < numberOfDistributions; i++) {
        const recipient = Keypair.generate().publicKey;
        const recipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;
        recipientAccounts.push(recipientATA);

        // Construct ix to transfer tokens from handler to the recipient.
        const transferInstruction = createTransferCheckedInstruction(
          handlerATA,
          mint,
          recipientATA,
          handlerSigner,
          distributionAmount,
          tokenDecimals
        );
        transferInstructions.push(transferInstruction);
      }

      const multicallHandlerCoder = new MulticallHandlerCoder(transferInstructions);

      const handlerMessage = multicallHandlerCoder.encode();

      const message = new AcrossPlusMessageCoder({
        handler: handlerProgram.programId,
        readOnlyLen: multicallHandlerCoder.readOnlyLen,
        valueAmount: new BN(0),
        accounts: multicallHandlerCoder.compiledMessage.accountKeys,
        handlerMessage,
      });

      const encodedMessage = message.encode();

      // Update relay data with the encoded message and total relay amount.
      const newRelayData = {
        ...relayData,
        message: encodedMessage,
        outputAmount: new BN(distributionAmount * numberOfDistributions),
      };
      updateRelayData(newRelayData);

      // Prepare request and execute slow fill instructions as we will need to use Address Lookup Table (ALT).
      // Request and execute slow fill.
      const { loadRequestParamsInstructions, requestIx, loadExecuteParamsInstructions, executeIx } =
        await createSlowFillIx(multicallHandlerCoder, bufferParams);

      // Fill using the ALT and submit load params transactions if needed.
      const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 });
      if (bufferParams) {
        for (let i = 0; i < loadRequestParamsInstructions.length; i += 1) {
          await sendAndConfirmTransaction(
            program.provider.connection,
            new Transaction().add(loadRequestParamsInstructions[i]),
            [relayer]
          );
        }
      }
      await sendTransactionWithLookupTable(connection, [computeBudgetIx, requestIx], relayer);
      await new Promise((resolve) => setTimeout(resolve, 1000)); // Make sure request tx gets processed.
      if (bufferParams) {
        for (let i = 0; i < loadExecuteParamsInstructions.length; i += 1) {
          await sendAndConfirmTransaction(
            program.provider.connection,
            new Transaction().add(loadExecuteParamsInstructions[i]),
            [relayer]
          );
        }
      }
      await sendTransactionWithLookupTable(connection, [computeBudgetIx, executeIx], relayer);

      // Verify vault's balance after the fill
      await new Promise((resolve) => setTimeout(resolve, 1000)); // Make sure token transfers get processed.
      const fVaultBal = (await getAccount(connection, vault)).amount;
      assertSE(
        fVaultBal,
        iVaultBal - BigInt(distributionAmount * numberOfDistributions),
        "Vault's balance should be reduced by the relay amount"
      );

      // Verify all recipient account balances after the fill.
      const recipientBalances = await Promise.all(
        recipientAccounts.map(async (account) => (await connection.getTokenAccountBalance(account)).value.amount)
      );
      recipientBalances.forEach((balance, i) => {
        assertSE(balance, distributionAmount, `Recipient account ${i} balance should match distribution amount`);
      });
    };

    it("Max token distributions within invoked message call, regular params", async () => {
      // Larger distribution would exceed message size limits.
      const numberOfDistributions = 5;

      await fillTokenDistributions(numberOfDistributions);
    });

    it("Max token distributions within invoked message call, buffer account params", async () => {
      // Larger distribution count hits inner instruction size limit when invoking CPI to message handler on public
      // devnet. On localnet this is not an issue, but we hit out of memory panic above 34 distributions.
      const numberOfDistributions = 19;

      await fillTokenDistributions(numberOfDistributions, true);
    });
  });

  it("Can recover and close fill status PDA from event data", async () => {
    // Construct ix to transfer all tokens from handler to the final recipient.
    const transferIx = createTransferCheckedInstruction(
      handlerATA,
      mint,
      finalRecipientATA,
      handlerSigner,
      relayData.outputAmount.toNumber(),
      tokenDecimals
    );

    const multicallHandlerCoder = new MulticallHandlerCoder([transferIx]);

    const handlerMessage = multicallHandlerCoder.encode();

    const message = new AcrossPlusMessageCoder({
      handler: handlerProgram.programId,
      readOnlyLen: multicallHandlerCoder.readOnlyLen,
      valueAmount: new BN(0),
      accounts: multicallHandlerCoder.compiledMessage.accountKeys,
      handlerMessage,
    });

    const encodedMessage = message.encode();

    // Update relay data with the encoded message.
    const newRelayData = { ...relayData, message: encodedMessage };
    updateRelayData(newRelayData);

    // Prepare request and execute slow fill instructions as we will need to use Address Lookup Table (ALT).
    // Request and execute slow fill.
    const { loadRequestParamsInstructions, requestIx, loadExecuteParamsInstructions, executeIx } =
      await createSlowFillIx(multicallHandlerCoder, true);

    // Fill using the ALT and submit load params transactions.
    for (let i = 0; i < loadRequestParamsInstructions.length; i += 1) {
      await sendAndConfirmTransaction(
        program.provider.connection,
        new Transaction().add(loadRequestParamsInstructions[i]),
        [relayer]
      );
    }
    await sendTransactionWithLookupTable(connection, [requestIx], relayer);
    await new Promise((resolve) => setTimeout(resolve, 1000)); // Make sure request tx gets processed.
    for (let i = 0; i < loadExecuteParamsInstructions.length; i += 1) {
      await sendAndConfirmTransaction(
        program.provider.connection,
        new Transaction().add(loadExecuteParamsInstructions[i]),
        [relayer]
      );
    }
    const { txSignature } = await sendTransactionWithLookupTable(connection, [executeIx], relayer);
    await connection.confirmTransaction(txSignature, "confirmed");
    await connection.getTransaction(txSignature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });

    // We don't close ALT here as that would require ~4 minutes between deactivation and closing, but we demonstrate
    // being able to close the fill status PDA using only event data.
    const events = await readEventsUntilFound(connection, txSignature, [program]);
    const eventData = events.find((event) => event.name === "filledRelay")?.data;
    assert.isNotNull(eventData, "FilledRelay event should be emitted");

    // Recover relay hash and derived fill status from event data.
    const relayHashUint8Array = calculateRelayEventHashUint8Array(eventData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );
    const fillStatusAccount = await program.account.fillStatusAccount.fetch(fillStatusPDA);
    assert.isTrue("filled" in fillStatusAccount.status, "Fill status account should be marked as filled");
    assertSE(fillStatusAccount.relayer, relayer.publicKey, "Relayer should match in the fill status");

    // Set the current time to past the fill deadline
    await setCurrentTime(program, state, relayer, new BN(fillStatusAccount.fillDeadline + 1));

    const closeFillPdaAccounts = {
      signer: relayer.publicKey,
      state,
      fillStatus: fillStatusPDA,
    };
    await program.methods.closeFillPda().accounts(closeFillPdaAccounts).signers([relayer]).rpc();

    // Verify the fill PDA is closed
    const fillStatusAccountAfter = await connection.getAccountInfo(fillStatusPDA);
    assert.isNull(fillStatusAccountAfter, "Fill PDA should be closed after closing");
  });
});
