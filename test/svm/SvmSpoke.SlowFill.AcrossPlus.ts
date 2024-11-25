import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { BN, Program } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount,
  createTransferCheckedInstruction,
  getAssociatedTokenAddressSync,
  createAssociatedTokenAccountInstruction,
  getMinimumBalanceForRentExemptAccount,
  createApproveCheckedInstruction,
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
} from "../../src/SvmUtils";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { FillDataParams, FillDataValues, common } from "./SvmSpoke.common";
import {
  SlowFillLeaf,
  loadExecuteV3SlowRelayLeafParams,
  loadFillV3RelayParams,
  loadRequestV3SlowFillParams,
  slowFillHashFn,
} from "./utils";
const { provider, connection, program, owner, chainId, seedBalance } = common;
const { initializeState, assertSE } = common;

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

  const formatRelayData = (relayData: SlowFillLeaf["relayData"]) => {
    return {
      ...relayData,
      depositId: relayData.depositId.toNumber(),
      fillDeadline: relayData.fillDeadline.toNumber(),
      exclusivityDeadline: relayData.exclusivityDeadline.toNumber(),
    };
  };

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

    const requestV3SlowFillValues = [Array.from(relayHash), formatRelayData(leaf.relayData)];
    let loadRequestParamsInstructions: TransactionInstruction[] = [];
    if (bufferParams) {
      loadRequestParamsInstructions = await loadRequestV3SlowFillParams(program, relayer, requestV3SlowFillValues[1]);
      [requestAccounts.instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
        program.programId
      );
    }
    const requestV3SlowFillParams = bufferParams ? [requestV3SlowFillValues[0], null] : requestV3SlowFillValues;
    const requestIx = await program.methods
      .requestV3SlowFill(...requestV3SlowFillParams)
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
    const executeV3SlowRelayLeafValues = [
      Array.from(relayHash),
      { ...leaf, relayData: formatRelayData(relayData) },
      rootBundleId,
      proofAsNumbers,
    ];
    let loadExecuteParamsInstructions: TransactionInstruction[] = [];
    if (bufferParams) {
      loadExecuteParamsInstructions = await loadExecuteV3SlowRelayLeafParams(
        program,
        relayer,
        executeV3SlowRelayLeafValues[1],
        executeV3SlowRelayLeafValues[2],
        executeV3SlowRelayLeafValues[3]
      );
      [requestAccounts.instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
        program.programId
      );
    }
    const executeV3SlowRelayLeafParams = bufferParams
      ? [executeV3SlowRelayLeafValues[0], null, null, null]
      : executeV3SlowRelayLeafValues;
    const executeIx = await program.methods
      .executeV3SlowRelayLeaf(...executeV3SlowRelayLeafParams)
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
      inputAmount: new BN(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: new BN(Math.floor(Math.random() * 1000000)), // Unique ID for each test.
      fillDeadline: new BN(Math.floor(Date.now() / 1000) + 60), // 1 minute from now
      exclusivityDeadline: new BN(Math.floor(Date.now() / 1000) - 30), // Note we set time in past to avoid exclusivity deadline
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
    await sendAndConfirmTransaction(connection, new Transaction().add(executeIx), [relayer]);

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
      const numberOfDistributions = 6;

      await fillTokenDistributions(numberOfDistributions);
    });

    it("Max token distributions within invoked message call, buffer account params", async () => {
      // Larger distribution count hits inner instruction size limit when invoking CPI to message handler on public
      // devnet. On localnet this is not an issue, but we hit out of memory panic above 34 distributions.
      const numberOfDistributions = 19;

      await fillTokenDistributions(numberOfDistributions, true);
    });
  });
});
