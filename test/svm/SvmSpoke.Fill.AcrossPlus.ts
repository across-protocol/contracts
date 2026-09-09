import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { assert } from "chai";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import { AccountMeta, Keypair, PublicKey, Transaction } from "@solana/web3.js";
import {
  AcrossPlusMessageCoder,
  MulticallHandlerCoder,
  calculateRelayHashUint8Array,
  getFillRelayDelegatePda,
  intToU8Array32,
  loadFillRelayParams,
  processEventFromTx,
} from "../../src/svm/web3-v1";
import { FillDataParams, FillDataValues } from "../../src/types/svm";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, chainId, seedBalance, initializeState } = common;

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

  for (const buffered of [false, true]) {
    for (const validCallback of [false, true]) {
      it(`rejects ${validCallback ? "encoded callback" : "malformed message"} with ${buffered ? "buffered" : "inline"} params atomically`, async () => {
        // A valid callback with a destination SOL transfer fits inline without a lookup table.
        const coder = new MulticallHandlerCoder([], finalRecipient);
        const message = validCallback
          ? new AcrossPlusMessageCoder({
              handler: handlerProgram.programId,
              readOnlyLen: coder.readOnlyLen,
              valueAmount: new BN(1_000_000),
              accounts: coder.compiledMessage.accountKeys,
              handlerMessage: coder.encode(),
            }).encode()
          : Buffer.from([1]);
        updateRelayData({ ...relayData, message });
        const { approveIx, fillIx } = await createApproveAndFillIx(coder, buffered);
        const watched = [
          relayerATA,
          handlerATA,
          finalRecipientATA,
          finalRecipient,
          relayer.publicKey,
          handlerSigner,
          accounts.fillStatus,
        ];
        if (buffered) watched.push(accounts.instructionParams);
        const before = await connection.getMultipleAccountsInfo(watched);
        const tx = new Transaction().add(approveIx, fillIx);
        tx.feePayer = payer.publicKey;
        const latest = await connection.getLatestBlockhash();
        tx.recentBlockhash = latest.blockhash;
        tx.sign(payer, relayer);
        const signature = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: true });
        const confirmation = await connection.confirmTransaction({ signature, ...latest }, "confirmed");
        assert.isNotNull(confirmation.value.err);
        let receipt = await connection.getTransaction(signature, {
          commitment: "confirmed",
          maxSupportedTransactionVersion: 0,
        });
        for (let n = 0; !receipt && n < 50; n++) {
          await new Promise((resolve) => setTimeout(resolve, 100));
          receipt = await connection.getTransaction(signature, {
            commitment: "confirmed",
            maxSupportedTransactionVersion: 0,
          });
        }
        assert.isNotNull(receipt);
        const logs = receipt!.meta!.logMessages ?? [];
        assert.include(logs.join("\n"), "LegacyFillMessageUnsupported");
        assert.isFalse(logs.some((log) => log.startsWith(`Program ${handlerProgram.programId} invoke`)));
        assert.isEmpty(processEventFromTx(receipt!, [program]).filter((event) => event.name === "filledRelay"));
        assert.deepEqual(
          await connection.getMultipleAccountsInfo(watched),
          before,
          "tokens, delegation, lamports, status and buffer must roll back"
        );
        assert.isNull(await connection.getAccountInfo(accounts.fillStatus));
      });
    }
  }
});
