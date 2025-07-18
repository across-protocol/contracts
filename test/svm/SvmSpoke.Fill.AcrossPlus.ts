import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { getApproveCheckedInstruction } from "@solana-program/token";
import {
  AccountRole,
  address,
  appendTransactionMessageInstruction,
  createKeyPairFromBytes,
  createSignerFromKeyPair,
  getProgramDerivedAddress,
  IAccountMeta,
  pipe,
} from "@solana/kit";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccountInstruction,
  createMint,
  createTransferCheckedInstruction,
  getAccount,
  getAssociatedTokenAddressSync,
  getMinimumBalanceForRentExemptAccount,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import {
  AccountMeta,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  sendAndConfirmTransaction,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { createDefaultTransaction, signAndSendTransaction, SvmSpokeClient } from "../../src/svm";
import { FillRelayAsyncInput } from "../../src/svm/clients/SvmSpoke";
import {
  AcrossPlusMessageCoder,
  calculateRelayHashUint8Array,
  getFillRelayDelegatePda,
  intToU8Array32,
  loadFillRelayParams,
  MulticallHandlerCoder,
  sendTransactionWithLookupTable as sendTransactionWithLookupTableV1,
} from "../../src/svm/web3-v1";
import { FillDataParams, FillDataValues } from "../../src/types/svm";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { common } from "./SvmSpoke.common";
import { createDefaultSolanaClient } from "./utils";
const { provider, connection, program, owner, chainId, seedBalance, initializeState, assertSE } = common;

describe("svm_spoke.fill.across_plus", () => {
  anchor.setProvider(provider);
  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;
  const relayer = Keypair.generate();

  const handlerProgram = anchor.workspace.MulticallHandler as Program<MulticallHandler>;

  let handlerSigner: PublicKey,
    handlerATA: PublicKey,
    finalRecipient: PublicKey,
    finalRecipientATA: PublicKey,
    state: PublicKey,
    mint: PublicKey,
    relayerATA: PublicKey,
    seed: BN;

  const relayAmount = 500000;
  const mintDecimals = 6;
  let relayData: any; // reused relay data for all tests.
  let accounts: any; // Store accounts to simplify contract interactions.

  const updateRelayData = (newRelayData: any) => {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    accounts = {
      state,
      delegate: getFillRelayDelegatePda(relayHashUint8Array, new BN(1), relayer.publicKey, program.programId).pda,
      signer: relayer.publicKey,
      instructionParams: program.programId,
      mint: mint,
      relayerTokenAccount: relayerATA,
      recipientTokenAccount: handlerATA,
      fillStatus: fillStatusPDA,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
  };

  const createApproveAndFillIx = async (multicallHandlerCoder: MulticallHandlerCoder, bufferParams = false) => {
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const relayHash = Array.from(relayHashUint8Array);

    // Delegate state PDA to pull relayer tokens.
    const approveIx = await createApproveCheckedInstruction(
      accounts.relayerTokenAccount,
      accounts.mint,
      getFillRelayDelegatePda(relayHashUint8Array, new BN(1), relayer.publicKey, program.programId).pda,
      accounts.signer,
      BigInt(relayAmount),
      mintDecimals
    );

    const remainingAccounts: AccountMeta[] = [
      { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
      ...multicallHandlerCoder.compiledKeyMetas,
    ];

    // Prepare fill instruction.
    const fillRelayValues: FillDataValues = [relayHash, relayData, new BN(1), relayer.publicKey];
    if (bufferParams) {
      await loadFillRelayParams(program, relayer, fillRelayValues[1], fillRelayValues[2], fillRelayValues[3]);
      [accounts.instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
        program.programId
      );
    }
    const fillRelayParams: FillDataParams = bufferParams ? [fillRelayValues[0], null, null, null] : fillRelayValues;
    const fillIx = await program.methods
      .fillRelay(...fillRelayParams)
      .accounts(accounts)
      .remainingAccounts(remainingAccounts)
      .instruction();

    return { approveIx, fillIx };
  };

  before("Creates token mint and associated token accounts", async () => {
    mint = await createMint(connection, payer, owner, owner, mintDecimals);
    relayerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;

    await mintTo(connection, payer, mint, relayerATA, owner, seedBalance);

    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL

    [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);
    handlerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, handlerSigner, true)).address;
  });

  beforeEach(async () => {
    finalRecipient = Keypair.generate().publicKey;
    finalRecipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, finalRecipient)).address;

    ({ state, seed } = await initializeState());

    const initialRelayData = {
      depositor: finalRecipient,
      recipient: handlerSigner, // Handler PDA that can forward tokens as needed within the message call.
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: intToU8Array32(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: new BN(Math.floor(Date.now() / 1000) + 60), // 1 minute from now
      exclusivityDeadline: new BN(Math.floor(Date.now() / 1000) + 30), // 30 seconds from now
      message: Buffer.from(""), // Will be populated in the tests below.
    };

    updateRelayData(initialRelayData);
  });

  it("Forwards tokens to the final recipient within invoked message call", async () => {
    const iRelayerBal = (await getAccount(connection, relayerATA)).amount;

    // Construct ix to transfer all tokens from handler to the final recipient.
    const transferIx = createTransferCheckedInstruction(
      handlerATA,
      mint,
      finalRecipientATA,
      handlerSigner,
      relayData.outputAmount,
      mintDecimals
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

    // Send approval and fill in one transaction.
    const { approveIx, fillIx } = await createApproveAndFillIx(multicallHandlerCoder);
    await sendAndConfirmTransaction(connection, new Transaction().add(approveIx, fillIx), [relayer]);

    // Verify relayer's balance after the fill
    const fRelayerBal = (await getAccount(connection, relayerATA)).amount;
    assertSE(fRelayerBal, iRelayerBal - BigInt(relayAmount), "Relayer's balance should be reduced by the relay amount");

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
      const iRelayerBal = (await getAccount(connection, relayerATA)).amount;

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
          mintDecimals
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

      // Prepare approval and fill instructions as we will need to use Address Lookup Table (ALT).
      const { approveIx, fillIx } = await createApproveAndFillIx(multicallHandlerCoder, bufferParams);

      // Fill using the ALT.
      const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 });
      await sendTransactionWithLookupTableV1(connection, [computeBudgetIx, approveIx, fillIx], relayer);

      // Verify relayer's balance after the fill
      await new Promise((resolve) => setTimeout(resolve, 500)); // Make sure token transfers get processed.
      const fRelayerBal = (await getAccount(connection, relayerATA)).amount;
      assertSE(
        fRelayerBal,
        iRelayerBal - BigInt(distributionAmount * numberOfDistributions),
        "Relayer's balance should be reduced by the relay amount"
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

  it("Sends lamports from the relayer to value recipient", async () => {
    const valueAmount = new BN(1_000_000_000);
    const valueRecipient = Keypair.generate().publicKey;

    const multicallHandlerCoder = new MulticallHandlerCoder([], valueRecipient);

    const handlerMessage = multicallHandlerCoder.encode();

    const message = new AcrossPlusMessageCoder({
      handler: handlerProgram.programId,
      readOnlyLen: multicallHandlerCoder.readOnlyLen,
      valueAmount,
      accounts: multicallHandlerCoder.compiledMessage.accountKeys,
      handlerMessage,
    });

    const encodedMessage = message.encode();

    // Update relay data with the encoded message.
    const newRelayData = { ...relayData, message: encodedMessage };
    updateRelayData(newRelayData);

    // Send approval and fill in one transaction.
    const { approveIx, fillIx } = await createApproveAndFillIx(multicallHandlerCoder);
    await sendAndConfirmTransaction(connection, new Transaction().add(approveIx, fillIx), [relayer]);

    // Verify value recipient balance.
    const valueRecipientAccount = await connection.getAccountInfo(valueRecipient);
    if (valueRecipientAccount === null) throw new Error("Account not found");
    assertSE(
      valueRecipientAccount.lamports,
      valueAmount.toNumber(),
      "Value recipient's balance should be increased by the value amount"
    );
  });

  it("Creates new ATA when forwarding tokens within invoked message call", async () => {
    // We need precise estimate of required funding for ATA creation.
    const valueAmount = await getMinimumBalanceForRentExemptAccount(connection);

    const anotherRecipient = Keypair.generate().publicKey;
    const anotherRecipientATA = getAssociatedTokenAddressSync(mint, anotherRecipient);

    // Construct ix to create recipient ATA funded via handler PDA.
    const createTokenAccountInstruction = createAssociatedTokenAccountInstruction(
      handlerSigner,
      anotherRecipientATA,
      anotherRecipient,
      mint
    );

    // Construct ix to transfer all tokens from handler to the recipient ATA.
    const transferInstruction = createTransferCheckedInstruction(
      handlerATA,
      mint,
      anotherRecipientATA,
      handlerSigner,
      relayData.outputAmount,
      mintDecimals
    );

    // Encode both instructions with handler PDA as the payer for ATA initialization.
    const multicallHandlerCoder = new MulticallHandlerCoder(
      [createTokenAccountInstruction, transferInstruction],
      handlerSigner
    );
    const handlerMessage = multicallHandlerCoder.encode();
    const message = new AcrossPlusMessageCoder({
      handler: handlerProgram.programId,
      readOnlyLen: multicallHandlerCoder.readOnlyLen,
      valueAmount: new BN(valueAmount), // Must exactly cover ATA creation.
      accounts: multicallHandlerCoder.compiledMessage.accountKeys,
      handlerMessage,
    });
    const encodedMessage = message.encode();

    // Update relay data with the encoded message.
    const newRelayData = { ...relayData, message: encodedMessage };
    updateRelayData(newRelayData);

    // Prepare approval and fill instructions as we will need to use Address Lookup Table (ALT).
    const { approveIx, fillIx } = await createApproveAndFillIx(multicallHandlerCoder);

    // Fill using the ALT.
    await sendTransactionWithLookupTableV1(connection, [approveIx, fillIx], relayer);

    // Verify recipient's balance after the fill
    await new Promise((resolve) => setTimeout(resolve, 500)); // Make sure token transfer gets processed.
    const anotherRecipientAccount = await getAccount(connection, anotherRecipientATA);
    assertSE(
      anotherRecipientAccount.amount,
      relayAmount,
      "Recipient's balance should be increased by the relay amount"
    );
  });

  describe("codama client and solana kit", () => {
    it("Forwards tokens to the final recipient within invoked message call using codama client", async () => {
      const iRelayerBal = (await getAccount(connection, relayerATA)).amount;

      // Construct ix to transfer all tokens from handler to the final recipient.
      const transferIx = createTransferCheckedInstruction(
        handlerATA,
        mint,
        finalRecipientATA,
        handlerSigner,
        relayData.outputAmount,
        mintDecimals
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

      const rpcClient = createDefaultSolanaClient();
      const signer = await createSignerFromKeyPair(await createKeyPairFromBytes(relayer.secretKey));

      const [eventAuthority] = await getProgramDerivedAddress({
        programAddress: address(program.programId.toString()),
        seeds: ["__event_authority"],
      });

      const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
      const relayHash = Array.from(relayHashUint8Array);
      const delegate = address(
        getFillRelayDelegatePda(relayHashUint8Array, new BN(1), relayer.publicKey, program.programId).pda.toString()
      );
      const formattedAccounts = {
        state: address(accounts.state.toString()),
        delegate,
        instructionParams: address(program.programId.toString()),
        mint: address(mint.toString()),
        relayerTokenAccount: address(relayerATA.toString()),
        recipientTokenAccount: address(handlerATA.toString()),
        fillStatus: address(accounts.fillStatus.toString()),
        tokenProgram: address(TOKEN_PROGRAM_ID.toString()),
        associatedTokenProgram: address(ASSOCIATED_TOKEN_PROGRAM_ID.toString()),
        systemProgram: address(anchor.web3.SystemProgram.programId.toString()),
        program: address(program.programId.toString()),
        eventAuthority,
        signer,
      };

      const formattedRelayData = {
        relayHash: new Uint8Array(relayHash),
        relayData: {
          depositor: address(relayData.depositor.toString()),
          recipient: address(relayData.recipient.toString()),
          exclusiveRelayer: address(relayData.exclusiveRelayer.toString()),
          inputToken: address(relayData.inputToken.toString()),
          outputToken: address(relayData.outputToken.toString()),
          inputAmount: new Uint8Array(relayData.inputAmount),
          outputAmount: relayData.outputAmount.toNumber(),
          originChainId: relayData.originChainId.toNumber(),
          depositId: new Uint8Array(relayData.depositId),
          fillDeadline: relayData.fillDeadline,
          exclusivityDeadline: relayData.exclusivityDeadline,
          message: encodedMessage,
        },
        repaymentChainId: 1,
        repaymentAddress: address(relayer.publicKey.toString()),
      };

      const approveIx = getApproveCheckedInstruction({
        source: address(accounts.relayerTokenAccount.toString()),
        mint: address(accounts.mint.toString()),
        delegate,
        owner: address(accounts.signer.toString()),
        amount: BigInt(relayData.outputAmount.toString()),
        decimals: mintDecimals,
      });

      const fillRelayInput: FillRelayAsyncInput = {
        ...formattedRelayData,
        ...formattedAccounts,
      };

      const fillRelayIxData = await SvmSpokeClient.getFillRelayInstructionAsync(fillRelayInput);
      const fillRelayIx = {
        ...fillRelayIxData,
        accounts: fillRelayIxData.accounts.map((account) =>
          account.address === program.programId.toString() ||
          account.address === TOKEN_PROGRAM_ID.toString() ||
          account.address === ASSOCIATED_TOKEN_PROGRAM_ID.toString()
            ? { ...account, role: AccountRole.READONLY }
            : account
        ),
      };

      const _remainingAccounts: AccountMeta[] = [
        { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
        ...multicallHandlerCoder.compiledKeyMetas,
      ];
      const remainingAccounts: IAccountMeta<string>[] = _remainingAccounts.map((account) => ({
        address: address(account.pubkey.toString()),
        role: account.isWritable ? AccountRole.WRITABLE : AccountRole.READONLY,
      }));
      (fillRelayIx.accounts as IAccountMeta<string>[]).push(...remainingAccounts);

      await pipe(
        await createDefaultTransaction(rpcClient, signer),
        (tx) => appendTransactionMessageInstruction(approveIx, tx),
        (tx) => appendTransactionMessageInstruction(fillRelayIx, tx),
        (tx) => signAndSendTransaction(rpcClient, tx)
      );

      // Verify relayer's balance after the fill
      const fRelayerBal = (await getAccount(connection, relayerATA)).amount;
      assertSE(
        fRelayerBal,
        iRelayerBal - BigInt(relayAmount),
        "Relayer's balance should be reduced by the relay amount"
      );

      // Verify final recipient's balance after the fill
      const finalRecipientAccount = await getAccount(connection, finalRecipientATA);
      assertSE(
        finalRecipientAccount.amount,
        relayAmount,
        "Final recipient's balance should be increased by the relay amount"
      );
    });
  });
});
