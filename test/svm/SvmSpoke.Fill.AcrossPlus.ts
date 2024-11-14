import * as anchor from "@coral-xyz/anchor";
import { BN, Program, web3 } from "@coral-xyz/anchor";
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
} from "@solana/spl-token";
import {
  PublicKey,
  Keypair,
  AccountMeta,
  TransactionMessage,
  AddressLookupTableProgram,
  VersionedTransaction,
} from "@solana/web3.js";
import { calculateRelayHashUint8Array, MulticallHandlerCoder, AcrossPlusMessageCoder } from "../../src/SvmUtils";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, chainId, seedBalance } = common;
const { initializeState, assertSE } = common;

describe("svm_spoke.fill.across_plus", () => {
  anchor.setProvider(provider);
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const relayer = Keypair.generate();

  const handlerProgram = anchor.workspace.MulticallHandler as Program<MulticallHandler>;

  let handlerSigner: PublicKey,
    handlerATA: PublicKey,
    finalRecipient: PublicKey,
    finalRecipientATA: PublicKey,
    state: PublicKey,
    mint: PublicKey,
    relayerATA: PublicKey;

  const relayAmount = 500000;
  const mintDecimals = 6;
  let relayData: any; // reused relay data for all tests.
  let accounts: any; // Store accounts to simplify contract interactions.

  function updateRelayData(newRelayData: any) {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    accounts = {
      state,
      signer: relayer.publicKey,
      mintAccount: mint,
      relayerTokenAccount: relayerATA,
      recipientTokenAccount: handlerATA,
      fillStatus: fillStatusPDA,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
  }

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

    state = await initializeState();

    const initialRelayData = {
      depositor: finalRecipient,
      recipient: handlerSigner, // Handler PDA that can forward tokens as needed within the message call.
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: new BN(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: new BN(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: new BN(Math.floor(Date.now() / 1000) + 60), // 1 minute from now
      exclusivityDeadline: new BN(Math.floor(Date.now() / 1000) + 30), // 30 seconds from now
      message: Buffer.from(""), // Will be populated in the tests below.
    };

    updateRelayData(initialRelayData);
  });

  it("Forwards tokens to the final recipient within invoked message call", async () => {
    // Verify relayer's balance before the fill
    let relayerAccount = await getAccount(connection, relayerATA);
    assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

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

    const remainingAccounts: AccountMeta[] = [
      { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
      ...multicallHandlerCoder.compiledKeyMetas,
    ];

    const relayHash = Array.from(calculateRelayHashUint8Array(newRelayData, chainId));

    await program.methods
      .fillV3Relay(relayHash, relayData, new BN(1), relayer.publicKey)
      .accounts(accounts)
      .remainingAccounts(remainingAccounts)
      .signers([relayer])
      .rpc();

    // Verify relayer's balance after the fill
    relayerAccount = await getAccount(connection, relayerATA);
    assertSE(
      relayerAccount.amount,
      seedBalance - relayAmount,
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

    const remainingAccounts: AccountMeta[] = [
      { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
      ...multicallHandlerCoder.compiledKeyMetas,
    ];

    const relayHash = Array.from(calculateRelayHashUint8Array(newRelayData, chainId));

    await program.methods
      .fillV3Relay(relayHash, relayData, new BN(1), relayer.publicKey)
      .accounts(accounts)
      .remainingAccounts(remainingAccounts)
      .signers([relayer])
      .rpc();

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
    // We need precise estimate of the minimum balance for ATA creation.
    const valueAmount = await getMinimumBalanceForRentExemptAccount(connection);

    const anotherRecipient = Keypair.generate().publicKey;
    const anotherRecipientATA = getAssociatedTokenAddressSync(mint, anotherRecipient);

    // Construct ix to create recipient ATA.
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
      valueAmount: new BN(valueAmount), // Should exactly cover ATA creation.
      accounts: multicallHandlerCoder.compiledMessage.accountKeys,
      handlerMessage,
    });
    const encodedMessage = message.encode();

    // Update relay data with the encoded message.
    const newRelayData = { ...relayData, message: encodedMessage };
    updateRelayData(newRelayData);

    const remainingAccounts: AccountMeta[] = [
      { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
      ...multicallHandlerCoder.compiledKeyMetas,
    ];

    const relayHash = Array.from(calculateRelayHashUint8Array(newRelayData, chainId));

    // Prepare fill instruction as we will need to use Address Lookup Table (ALT).
    const fillInstruction = await program.methods
      .fillV3Relay(relayHash, relayData, new BN(1), relayer.publicKey)
      .accounts(accounts)
      .remainingAccounts(remainingAccounts)
      .signers([relayer])
      .instruction();

    // Consolidate all above addresses into a single array for the  ALT.
    const lookupAddresses = [...Object.values(accounts), ...remainingAccounts.map((acc) => acc.pubkey)];

    // Create instructions for creating and extending the ALT.
    const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
      authority: relayer.publicKey,
      payer: relayer.publicKey,
      recentSlot: await connection.getSlot(),
    });

    // Submit the ALT creation transaction
    await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(lookupTableInstruction), [relayer], {
      skipPreflight: true, // Avoids recent slot mismatch in simulation.
    });

    // Extend the ALT with all accounts
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: relayer.publicKey,
      payer: relayer.publicKey,
      addresses: lookupAddresses as PublicKey[],
    });
    await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(extendInstruction), [relayer], {
      skipPreflight: true, // Avoids recent slot mismatch in simulation.
    });

    // Avoids invalid ALT index as ALT might not be active yet on the following tx.
    await new Promise((resolve) => setTimeout(resolve, 1000));

    // Fetch the AddressLookupTableAccount
    const lookupTableAccount = (await connection.getAddressLookupTable(lookupTableAddress)).value;
    if (lookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");

    // Create the versioned transaction
    const versionedTx = new VersionedTransaction(
      new TransactionMessage({
        payerKey: relayer.publicKey,
        recentBlockhash: (await connection.getLatestBlockhash()).blockhash,
        instructions: [fillInstruction],
      }).compileToV0Message([lookupTableAccount])
    );

    // Sign and submit the versioned transaction.
    versionedTx.sign([relayer]);
    await connection.sendTransaction(versionedTx);

    // Verify recipient's balance after the fill
    await new Promise((resolve) => setTimeout(resolve, 500)); // Make sure token transfer gets processed.
    const anotherRecipientAccount = await getAccount(connection, anotherRecipientATA);
    assertSE(
      anotherRecipientAccount.amount,
      relayAmount,
      "Recipient's balance should be increased by the relay amount"
    );
  });
});