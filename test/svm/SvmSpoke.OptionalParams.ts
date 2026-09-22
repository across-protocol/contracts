import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, sendAndConfirmTransaction, Transaction } from "@solana/web3.js";
import {
  calculateRelayHashUint8Array,
  getFillRelayDelegatePda,
  intToU8Array32,
  loadFillRelayParams,
} from "../../src/svm/web3-v1";
import { RelayData, FillAccounts } from "../../src/types/svm";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, chainId, recipient, seedBalance, initializeState, assert } = common;

describe("svm_spoke.optional_params", () => {
  anchor.setProvider(provider);
  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;
  const relayer = Keypair.generate();

  let recipientATA: PublicKey,
    state: PublicKey,
    mint: PublicKey,
    relayerATA: PublicKey,
    instructionParams: PublicKey,
    fillStatusPDA: PublicKey,
    relayData: RelayData,
    relayHashUint8Array: Uint8Array,
    relayHash: number[],
    fillAccounts: FillAccounts;

  const relayAmount = 500000;
  const mintDecimals = 6;
  const originChainId = new BN(1);
  const repaymentChainId = new BN(1);
  const repaymentAddress = relayer.publicKey;

  type BooleanTuple<N extends number, T extends boolean[] = []> = T["length"] extends N
    ? T
    : BooleanTuple<N, [...T, boolean]>;

  const allBooleanCombos = <N extends number>(count: N): BooleanTuple<N>[] => {
    if (!Number.isInteger(count) || count < 0) {
      throw new RangeError("count must be a non-negative integer");
    }
    if (count > 10) {
      throw new RangeError("count must be <= 10 to avoid out of memory issues");
    }

    return Array.from({ length: 1 << count }, (_, i) => {
      const row = Array.from({ length: count }, (_, bit) => ((i >> (count - 1 - bit)) & 1) === 1);
      return row as BooleanTuple<N>;
    });
  };

  const validOptionalFillParamPresence = (
    nullRelayData: boolean,
    nullRepaymentChainId: boolean,
    nullRepaymentAddress: boolean,
    nullInstructionParams: boolean
  ): boolean => {
    return (
      (nullRelayData && nullRepaymentChainId && nullRepaymentAddress && !nullInstructionParams) ||
      (!nullRelayData && !nullRepaymentChainId && !nullRepaymentAddress && nullInstructionParams)
    );
  };

  const updateRelayData = async () => {
    relayData = {
      depositor: recipient,
      recipient: recipient,
      exclusiveRelayer: anchor.web3.SystemProgram.programId, // No exclusivity.
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: intToU8Array32(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId,
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
      exclusivityDeadline: 0, // Exclusivity is not used in this test.
      message: Buffer.from(""),
    };
    relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    relayHash = Array.from(relayHashUint8Array);
    [fillStatusPDA] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], program.programId);
  };

  const setUpFillTest = async () => {
    await updateRelayData();

    // Prepare instruction_params account, but some test iterations would not need it
    await loadFillRelayParams(program, relayer, relayData, repaymentChainId, repaymentAddress);

    fillAccounts = {
      signer: relayer.publicKey,
      instructionParams, // Can be overriden to program.programId in a test iteration
      state,
      delegate: getFillRelayDelegatePda(relayHashUint8Array, repaymentChainId, repaymentAddress, program.programId).pda,
      mint,
      relayerTokenAccount: relayerATA,
      recipientTokenAccount: recipientATA,
      fillStatus: fillStatusPDA,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
  };

  const testApproveAndFill = async (
    nullRelayData: boolean,
    nullRepaymentChainId: boolean,
    nullRepaymentAddress: boolean,
    nullInstructionParams: boolean
  ) => {
    // Set null values based on the tested parameter combinations
    const relayDataToUse = nullRelayData ? null : relayData;
    const repaymentChainIdToUse = nullRepaymentChainId ? null : repaymentChainId;
    const repaymentAddressToUse = nullRepaymentAddress ? null : repaymentAddress;
    const fillAccountsToUse = nullInstructionParams
      ? { ...fillAccounts, instructionParams: program.programId }
      : fillAccounts;

    const approveIx = await createApproveCheckedInstruction(
      fillAccountsToUse.relayerTokenAccount,
      fillAccountsToUse.mint,
      fillAccountsToUse.delegate,
      fillAccountsToUse.signer,
      BigInt(relayData.outputAmount.toString()),
      mintDecimals,
      undefined,
      fillAccountsToUse.tokenProgram
    );

    const fillIx = await program.methods
      .fillRelay(relayHash, relayDataToUse, repaymentChainIdToUse, repaymentAddressToUse)
      .accounts(fillAccountsToUse)
      .instruction();

    if (
      validOptionalFillParamPresence(nullRelayData, nullRepaymentChainId, nullRepaymentAddress, nullInstructionParams)
    ) {
      await sendAndConfirmTransaction(connection, new Transaction().add(approveIx, fillIx), [relayer]);

      // Since the transaction was successful, prepare for the next test iteration
      await setUpFillTest();
    } else {
      try {
        await sendAndConfirmTransaction(connection, new Transaction().add(approveIx, fillIx), [relayer]);
        assert.fail("Fill should have failed due to inconsistent optional params");
      } catch (err: any) {
        assert.include(
          err.toString(),
          "InconsistentOptionalParameters",
          "Expected InconsistentOptionalParameters error"
        );
      }
    }
  };

  before(async () => {
    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL

    [instructionParams] = PublicKey.findProgramAddressSync(
      [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
      program.programId
    );
  });

  beforeEach(async () => {
    ({ state } = await initializeState());

    // Creates token mint and associated token accounts
    mint = await createMint(connection, payer, owner, owner, mintDecimals);
    recipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;
    relayerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    await mintTo(connection, payer, mint, relayerATA, owner, seedBalance);
  });

  it("All fill_relay optional param combinations", async () => {
    await setUpFillTest();

    for (const [nullRelayData, nullRepaymentChainId, nullRepaymentAddress, nullInstructionParams] of allBooleanCombos(
      4
    )) {
      await testApproveAndFill(nullRelayData, nullRepaymentChainId, nullRepaymentAddress, nullInstructionParams);
    }
  });
});
