import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import * as crypto from "crypto";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, sendAndConfirmTransaction, Transaction } from "@solana/web3.js";
import { MerkleTree } from "../../utils/MerkleTree";
import {
  calculateRelayHashUint8Array,
  getFillRelayDelegatePda,
  intToU8Array32,
  loadExecuteSlowRelayLeafParams,
  loadFillRelayParams,
  loadRequestSlowFillParams,
  slowFillHashFn,
} from "../../src/svm/web3-v1";
import {
  RelayData,
  FillAccounts,
  RequestSlowFillAccounts,
  ExecuteSlowRelayLeafAccounts,
  SlowFillLeaf,
} from "../../src/types/svm";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, chainId, recipient, seedBalance, initializeState, assert } = common;

describe("svm_spoke.optional_params", () => {
  anchor.setProvider(provider);
  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;
  const relayer = Keypair.generate();

  let recipientATA: PublicKey,
    state: PublicKey,
    seed: BN,
    mint: PublicKey,
    relayerATA: PublicKey,
    vault: PublicKey,
    instructionParams: PublicKey,
    fillStatusPDA: PublicKey,
    relayData: RelayData,
    relayHashUint8Array: Uint8Array,
    relayHash: number[],
    slowRelayLeaf: SlowFillLeaf,
    rootBundleId: number,
    proofAsNumbers: number[][],
    fillAccounts: FillAccounts,
    requestSlowFillAccounts: RequestSlowFillAccounts,
    executeSlowRelayLeafAccounts: ExecuteSlowRelayLeafAccounts;

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

  const validOptionalRequestSlowFillParamPresence = (
    nullRelayData: boolean,
    nullInstructionParams: boolean
  ): boolean => {
    return nullRelayData !== nullInstructionParams;
  };

  const validOptionalExecuteSlowFillParamPresence = (
    nullSlowFillLeaf: boolean,
    nullRootBundleId: boolean,
    nullProof: boolean,
    nullInstructionParams: boolean
  ): boolean => {
    return (
      (nullSlowFillLeaf && nullRootBundleId && nullProof && !nullInstructionParams) ||
      (!nullSlowFillLeaf && !nullRootBundleId && !nullProof && nullInstructionParams)
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

  const setUpRequestSlowFillTest = async () => {
    await updateRelayData();

    // Prepare instruction_params account, but some test iterations would not need it
    const loadInstructions = await loadRequestSlowFillParams(program, relayer, relayData);
    for (let i = 0; i < loadInstructions.length; i += 1) {
      await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(loadInstructions[i]), [
        relayer,
      ]);
    }

    requestSlowFillAccounts = {
      signer: relayer.publicKey,
      instructionParams, // Can be overriden to program.programId in a test iteration
      state,
      fillStatus: fillStatusPDA,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
  };

  const setUpExecuteSlowFillTest = async () => {
    await updateRelayData();

    // Make slow fill request first
    requestSlowFillAccounts = {
      signer: relayer.publicKey,
      instructionParams: program.programId, // We test execution here, so no instruction_params account for the request.
      state,
      fillStatus: fillStatusPDA,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
    const requestSlowFillIx = await program.methods
      .requestSlowFill(relayHash, relayData)
      .accounts(requestSlowFillAccounts)
      .instruction();
    await sendAndConfirmTransaction(connection, new Transaction().add(requestSlowFillIx), [relayer]);

    // Prepare and relay slow fill root bundle
    slowRelayLeaf = {
      relayData,
      chainId,
      updatedOutputAmount: relayData.outputAmount,
    };
    const merkleTree = new MerkleTree<SlowFillLeaf>([slowRelayLeaf], slowFillHashFn);
    const slowRelayRoot = merkleTree.getRoot();
    const proof = merkleTree.getProof(slowRelayLeaf);
    proofAsNumbers = proof.map((p) => Array.from(p));
    const stateAccountData = await program.account.state.fetch(state);
    rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);
    const relayerRefundRoot = crypto.randomBytes(32);
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(Array.from(relayerRefundRoot), Array.from(slowRelayRoot))
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Prepare instruction_params account, but some test iterations would not need it
    const loadInstructions = await loadExecuteSlowRelayLeafParams(
      program,
      relayer,
      slowRelayLeaf,
      rootBundleId,
      proofAsNumbers
    );
    for (let i = 0; i < loadInstructions.length; i += 1) {
      await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(loadInstructions[i]), [
        relayer,
      ]);
    }

    executeSlowRelayLeafAccounts = {
      signer: relayer.publicKey,
      instructionParams, // Can be overriden to program.programId in a test iteration
      state,
      rootBundle,
      fillStatus: fillStatusPDA,
      mint,
      recipientTokenAccount: recipientATA,
      vault,
      tokenProgram: TOKEN_PROGRAM_ID,
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

  const testRequestSlowFill = async (nullRelayData: boolean, nullInstructionParams: boolean) => {
    // Set null values based on the tested parameter combinations
    const relayDataToUse = nullRelayData ? null : relayData;
    const requestSlowFillAccountsToUse = nullInstructionParams
      ? { ...requestSlowFillAccounts, instructionParams: program.programId }
      : requestSlowFillAccounts;

    const requestSlowFillIx = await program.methods
      .requestSlowFill(relayHash, relayDataToUse)
      .accounts(requestSlowFillAccountsToUse)
      .instruction();

    if (validOptionalRequestSlowFillParamPresence(nullRelayData, nullInstructionParams)) {
      await sendAndConfirmTransaction(connection, new Transaction().add(requestSlowFillIx), [relayer]);

      // Since the transaction was successful, prepare for the next test iteration
      await setUpRequestSlowFillTest();
    } else {
      try {
        await sendAndConfirmTransaction(connection, new Transaction().add(requestSlowFillIx), [relayer]);
        assert.fail("Request slow fill should have failed due to inconsistent optional params");
      } catch (err: any) {
        assert.include(
          err.toString(),
          "InconsistentOptionalParameters",
          "Expected InconsistentOptionalParameters error"
        );
      }
    }
  };

  const testExecuteSlowFill = async (
    nullSlowFillLeaf: boolean,
    nullRootBundleId: boolean,
    nullProof: boolean,
    nullInstructionParams: boolean
  ) => {
    // Set null values based on the tested parameter combinations
    const slowFillLeafToUse = nullSlowFillLeaf ? null : slowRelayLeaf;
    const rootBundleIdToUse = nullRootBundleId ? null : rootBundleId;
    const proofToUse = nullProof ? null : proofAsNumbers;
    const executeSlowFillAccountsToUse = nullInstructionParams
      ? { ...executeSlowRelayLeafAccounts, instructionParams: program.programId }
      : executeSlowRelayLeafAccounts;

    const executeSlowFillIx = await program.methods
      .executeSlowRelayLeaf(relayHash, slowFillLeafToUse, rootBundleIdToUse, proofToUse)
      .accounts(executeSlowFillAccountsToUse)
      .instruction();

    if (
      validOptionalExecuteSlowFillParamPresence(nullSlowFillLeaf, nullRootBundleId, nullProof, nullInstructionParams)
    ) {
      await sendAndConfirmTransaction(connection, new Transaction().add(executeSlowFillIx), [relayer]);

      // Since the transaction was successful, prepare for the next test iteration
      await setUpExecuteSlowFillTest();
    } else {
      try {
        await sendAndConfirmTransaction(connection, new Transaction().add(executeSlowFillIx), [relayer]);
        assert.fail("Execute slow fill should have failed due to inconsistent optional params");
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
    ({ state, seed } = await initializeState());

    // Creates token mint and associated token accounts
    mint = await createMint(connection, payer, owner, owner, mintDecimals);
    recipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;
    relayerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address;
    await mintTo(connection, payer, mint, relayerATA, owner, seedBalance);
    await mintTo(connection, payer, mint, vault, owner, seedBalance);
  });

  it("All fill_relay optional param combinations", async () => {
    await setUpFillTest();

    for (const [nullRelayData, nullRepaymentChainId, nullRepaymentAddress, nullInstructionParams] of allBooleanCombos(
      4
    )) {
      await testApproveAndFill(nullRelayData, nullRepaymentChainId, nullRepaymentAddress, nullInstructionParams);
    }
  });

  it("All request_slow_fill optional param combinations", async () => {
    await setUpRequestSlowFillTest();

    for (const [nullRelayData, nullInstructionParams] of allBooleanCombos(2)) {
      await testRequestSlowFill(nullRelayData, nullInstructionParams);
    }
  });

  it("All execute_slow_fill optional param combinations", async () => {
    await setUpExecuteSlowFillTest();

    for (const [nullSlowFillLeaf, nullRootBundleId, nullProof, nullInstructionParams] of allBooleanCombos(4)) {
      await testExecuteSlowFill(nullSlowFillLeaf, nullRootBundleId, nullProof, nullInstructionParams);
    }
  });
});
