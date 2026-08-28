import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import {
  ExtensionType,
  TOKEN_2022_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createInitializeMintInstruction,
  createInitializeTransferFeeConfigInstruction,
  createInitializeTransferHookInstruction,
  createMint,
  getAccount,
  getAssociatedTokenAddressSync,
  getMintLen,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import {
  AccountMeta,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import { assert } from "chai";
import { createHash } from "crypto";
import { ethers } from "ethers";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { readEventsUntilFound } from "../../src/svm/web3-v1";
import { common } from "./SvmSpoke.common";

const GATEWAY = new PublicKey("34trBszXuqhRjWaMxXWsunJNmyUsBvDNPxAwTzbPTm4p");
const V5_PREFIX = Buffer.from("89ae4bc75915265a3f10e926c3894a29534f1d6362ee8959cb0e5be00f3527fd", "hex");
const adapterDiscriminator = createHash("sha256").update("global:adapter_execute_across_v5").digest().subarray(0, 8);
const mockDiscriminator = createHash("sha256").update("global:execute_adapter").digest().subarray(0, 8);
const u16 = (value: number) => {
  const data = Buffer.alloc(2);
  data.writeUInt16LE(value);
  return data;
};
const u32 = (value: number) => {
  const data = Buffer.alloc(4);
  data.writeUInt32LE(value);
  return data;
};
const u64 = (value: bigint | number) => {
  const data = Buffer.alloc(8);
  data.writeBigUInt64LE(BigInt(value));
  return data;
};
const vec = (value: Buffer) => Buffer.concat([u32(value.length), value]);
const bytes32 = (value: bigint | number) =>
  Buffer.from(ethers.utils.zeroPad(ethers.BigNumber.from(value.toString()).toHexString(), 32));

type ContextValues = { stepId: Buffer; pathId: Buffer; submitter: PublicKey };
type DepositFields = {
  depositor: PublicKey;
  recipient: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: bigint;
  outputAmount: Buffer;
  destinationChainId: bigint;
  exclusiveRelayer: PublicKey;
  depositNonce: bigint;
  quoteTimestamp: number;
  fillDeadline: number;
  exclusivityParameter: number;
  dstStepId: Buffer;
};

const encodeContext = ({ stepId, pathId, submitter }: ContextValues) =>
  Buffer.concat([stepId, pathId, submitter.toBuffer()]);

const encodeDeposit = (
  deposit: DepositFields,
  amountMode: { literal: true } | { bips: number },
  rules: { authority: Buffer; output: boolean; relayer: boolean } = {
    authority: Buffer.alloc(20),
    output: false,
    relayer: false,
  }
) =>
  Buffer.concat([
    Buffer.from([1, 0]),
    deposit.depositor.toBuffer(),
    deposit.recipient.toBuffer(),
    deposit.inputToken.toBuffer(),
    deposit.outputToken.toBuffer(),
    u64(deposit.inputAmount),
    deposit.outputAmount,
    u64(deposit.destinationChainId),
    deposit.exclusiveRelayer.toBuffer(),
    u64(deposit.depositNonce),
    u32(deposit.quoteTimestamp),
    u32(deposit.fillDeadline),
    u32(deposit.exclusivityParameter),
    deposit.dstStepId,
    "literal" in amountMode ? Buffer.from([0]) : Buffer.concat([Buffer.from([1]), u16(amountMode.bips)]),
    rules.authority,
    Buffer.from([Number(rules.output), Number(rules.relayer)]),
  ]);

const signJit = (
  signer: ethers.Wallet,
  context: ContextValues,
  depositNonce: bigint,
  outputAmount: Buffer,
  exclusiveRelayer: PublicKey,
  domainProgram = GATEWAY
) => {
  const nameHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ACXV.AcrossDepositDelegateAdapter.V1"));
  const domain = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "bytes32"],
      [nameHash, ethers.utils.hexlify(domainProgram.toBuffer())]
    )
  );
  const digest = ethers.utils.keccak256(
    ethers.utils.solidityPack(
      ["bytes32", "bytes32", "uint256", "uint256", "bytes32"],
      [
        domain,
        ethers.utils.hexlify(context.pathId),
        depositNonce,
        ethers.utils.hexlify(outputAmount),
        ethers.utils.hexlify(exclusiveRelayer.toBuffer()),
      ]
    )
  );
  return Buffer.concat([
    outputAmount,
    exclusiveRelayer.toBuffer(),
    Buffer.from(ethers.utils.arrayify(ethers.utils.joinSignature(signer._signingKey().signDigest(digest)))),
  ]);
};

describe("svm_spoke V5 source deposit", () => {
  anchor.setProvider(common.provider);
  const { provider, connection, owner, initializeState, program } = common;
  const svmSpoke = program as Program<SvmSpoke>;
  const payer = (provider.wallet as anchor.Wallet).payer;
  const jitSigner = new ethers.Wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
  const [vaultAuthority] = PublicKey.findProgramAddressSync([Buffer.from("vault_authority")], GATEWAY);
  const [dispatchAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("dispatch_authority"), svmSpoke.programId.toBuffer()],
    GATEWAY
  );
  const [sourceDelegate] = PublicKey.findProgramAddressSync([Buffer.from("v5_source_delegate")], svmSpoke.programId);
  const [eventAuthority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], svmSpoke.programId);

  let state: PublicKey;
  let mint: PublicKey;
  let gatewayVault: PublicKey;
  let spokeVault: PublicKey;
  let tokenProgram = TOKEN_PROGRAM_ID;
  let context: ContextValues;
  let deposit: DepositFields;

  const remaining = (delegate = sourceDelegate, destination = spokeVault): AccountMeta[] => [
    { pubkey: gatewayVault, isSigner: false, isWritable: true },
    { pubkey: destination, isSigner: false, isWritable: true },
    { pubkey: mint, isSigner: false, isWritable: false },
    { pubkey: tokenProgram, isSigner: false, isWritable: false },
    { pubkey: delegate, isSigner: false, isWritable: false },
  ];

  const mockInstruction = (
    input: Buffer,
    jitData: Buffer,
    approval: bigint,
    failAfter = false,
    delegate = sourceDelegate,
    destination = spokeVault
  ) =>
    new TransactionInstruction({
      programId: GATEWAY,
      keys: [
        { pubkey: owner, isSigner: true, isWritable: false },
        { pubkey: vaultAuthority, isSigner: false, isWritable: false },
        { pubkey: dispatchAuthority, isSigner: false, isWritable: false },
        { pubkey: gatewayVault, isSigner: false, isWritable: true },
        { pubkey: destination, isSigner: false, isWritable: true },
        { pubkey: mint, isSigner: false, isWritable: false },
        { pubkey: delegate, isSigner: false, isWritable: false },
        { pubkey: state, isSigner: false, isWritable: false },
        { pubkey: eventAuthority, isSigner: false, isWritable: false },
        { pubkey: tokenProgram, isSigner: false, isWritable: false },
        { pubkey: svmSpoke.programId, isSigner: false, isWritable: false },
      ],
      data: Buffer.concat([
        mockDiscriminator,
        encodeContext(context),
        vec(input),
        vec(jitData),
        u64(approval),
        Buffer.from([Number(failAfter)]),
      ]),
    });

  const execute = async (
    input: Buffer,
    jitData = Buffer.alloc(0),
    approval = 1_000_000n,
    failAfter = false,
    delegate = sourceDelegate,
    destination = spokeVault
  ) =>
    provider.sendAndConfirm(
      new Transaction().add(mockInstruction(input, jitData, approval, failAfter, delegate, destination))
    );

  const expectError = async (promise: Promise<unknown>, name: string) => {
    try {
      await promise;
      assert.fail(`Expected ${name}`);
    } catch (error: any) {
      assert.include(error.toString(), name);
    }
  };

  const setInputMint = async (nextMint: PublicKey, nextTokenProgram: PublicKey, updateDeposit = false) => {
    mint = nextMint;
    tokenProgram = nextTokenProgram;
    gatewayVault = (
      await getOrCreateAssociatedTokenAccount(
        connection,
        payer,
        mint,
        vaultAuthority,
        true,
        undefined,
        undefined,
        tokenProgram
      )
    ).address;
    spokeVault = (
      await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true, undefined, undefined, tokenProgram)
    ).address;
    await mintTo(connection, payer, mint, gatewayVault, owner, 1_000_000, [], undefined, tokenProgram);
    if (updateDeposit) deposit.inputToken = mint;
  };

  const createExtendedMint = async (extension: ExtensionType) => {
    const mintKeypair = Keypair.generate();
    const mintLen = getMintLen([extension]);
    const initializeExtension =
      extension === ExtensionType.TransferFeeConfig
        ? createInitializeTransferFeeConfigInstruction(
            mintKeypair.publicKey,
            owner,
            owner,
            100,
            10_000n,
            TOKEN_2022_PROGRAM_ID
          )
        : createInitializeTransferHookInstruction(
            mintKeypair.publicKey,
            owner,
            Keypair.generate().publicKey,
            TOKEN_2022_PROGRAM_ID
          );
    await sendAndConfirmTransaction(
      connection,
      new Transaction().add(
        SystemProgram.createAccount({
          fromPubkey: payer.publicKey,
          newAccountPubkey: mintKeypair.publicKey,
          lamports: await connection.getMinimumBalanceForRentExemption(mintLen),
          space: mintLen,
          programId: TOKEN_2022_PROGRAM_ID,
        }),
        initializeExtension,
        createInitializeMintInstruction(mintKeypair.publicKey, 6, owner, owner, TOKEN_2022_PROGRAM_ID)
      ),
      [payer, mintKeypair]
    );
    return mintKeypair.publicKey;
  };

  beforeEach(async () => {
    ({ state } = await initializeState());
    await setInputMint(await createMint(connection, payer, owner, owner, 6), TOKEN_PROGRAM_ID);
    const now = (await svmSpoke.account.state.fetch(state)).currentTime;
    context = {
      stepId: Buffer.alloc(32, 0xaa),
      pathId: Buffer.alloc(32, 0xbb),
      submitter: Keypair.generate().publicKey,
    };
    deposit = {
      depositor: Keypair.generate().publicKey,
      recipient: Keypair.generate().publicKey,
      inputToken: mint,
      outputToken: Keypair.generate().publicKey,
      inputAmount: 500_000n,
      outputAmount: bytes32(450_000),
      destinationChainId: 1n,
      exclusiveRelayer: Keypair.generate().publicKey,
      depositNonce: 7n,
      quoteTimestamp: now - 1,
      fillDeadline: now + 600,
      exclusivityParameter: 0,
      dstStepId: Buffer.alloc(32, 0x77),
    };
  });

  it("resolves a balance amount, applies signed JIT, pulls exactly, and emits the standard event", async () => {
    const improvedOutput = bytes32(475_000);
    const newRelayer = Keypair.generate().publicKey;
    const input = encodeDeposit(
      deposit,
      { bips: 7500 },
      {
        authority: Buffer.from(jitSigner.address.slice(2), "hex"),
        output: true,
        relayer: true,
      }
    );
    const jit = signJit(jitSigner, context, deposit.depositNonce, improvedOutput, newRelayer);
    const signature = await execute(input, jit, 900_000n);

    assert.equal((await getAccount(connection, gatewayVault)).amount, 250_000n);
    assert.equal((await getAccount(connection, spokeVault)).amount, 750_000n);
    const event = (await readEventsUntilFound(connection, signature, [svmSpoke]))[0].data;
    const syntheticNonce = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "uint256"],
        [context.submitter.toBuffer(), context.pathId, deposit.depositNonce]
      )
    );
    const depositId = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "bytes32"],
        [GATEWAY.toBuffer(), deposit.depositor.toBuffer(), syntheticNonce]
      )
    );
    assert.equal(event.inputAmount.toString(), "750000");
    assert.equal(Buffer.from(event.outputAmount).toString("hex"), improvedOutput.toString("hex"));
    assert.equal(event.exclusiveRelayer.toString(), newRelayer.toString());
    assert.equal(Buffer.from(event.depositId).toString("hex"), depositId.slice(2));
    assert.equal(
      Buffer.from(event.message).toString("hex"),
      Buffer.concat([V5_PREFIX, deposit.dstStepId]).toString("hex")
    );
    assert.equal(event.depositor.toString(), deposit.depositor.toString());
  });

  it("rejects direct callers, the reserved Fill branch, and malformed wire", async () => {
    const input = encodeDeposit(deposit, { literal: true });
    const direct = new TransactionInstruction({
      programId: svmSpoke.programId,
      keys: [
        { pubkey: owner, isSigner: true, isWritable: false },
        { pubkey: state, isSigner: false, isWritable: false },
        { pubkey: eventAuthority, isSigner: false, isWritable: false },
        { pubkey: svmSpoke.programId, isSigner: false, isWritable: false },
        ...remaining(),
      ],
      data: Buffer.concat([adapterDiscriminator, encodeContext(context), vec(input), vec(Buffer.alloc(0))]),
    });
    await expectError(provider.sendAndConfirm(new Transaction().add(direct)), "InvalidDispatchAuthority");

    const fill = Buffer.concat([
      Buffer.from([1, 1]),
      deposit.recipient.toBuffer(),
      deposit.outputToken.toBuffer(),
      u64(1),
      u32(0),
    ]);
    await expectError(execute(fill), "UnsupportedMode");
    await expectError(execute(Buffer.concat([input, Buffer.from([0])])), "InvalidWireFormat");
  });

  it("rejects wrong delegate, wrong vault accounts, and insufficient allowance", async () => {
    const input = encodeDeposit(deposit, { literal: true });
    await expectError(execute(input, Buffer.alloc(0), 1_000_000n, false, owner), "MissingAccount");
    await expectError(
      execute(input, Buffer.alloc(0), 1_000_000n, false, sourceDelegate, gatewayVault),
      "MissingAccount"
    );
    await expectError(execute(input, Buffer.alloc(0), deposit.inputAmount - 1n), "InsufficientDelegateAllowance");
    await expectError(
      execute(encodeDeposit(deposit, { bips: 7500 }), Buffer.alloc(0), 700_000n),
      "InsufficientDelegateAllowance"
    );
    assert.equal((await getAccount(connection, gatewayVault)).amount, 1_000_000n);
    assert.equal((await getAccount(connection, spokeVault)).amount, 0n);
  });

  it("enforces paused deposits and the committed dynamic-amount floor", async () => {
    const input = encodeDeposit(deposit, { literal: true });
    await svmSpoke.methods.pauseDeposits(true).accounts({ state, signer: owner, program: svmSpoke.programId }).rpc();
    await expectError(execute(input), "DepositsArePaused");
    await svmSpoke.methods.pauseDeposits(false).accounts({ state, signer: owner, program: svmSpoke.programId }).rpc();
    await expectError(execute(encodeDeposit(deposit, { bips: 4000 })), "ResolvedInputAmountBelowCommitted");
  });

  it("supports plain Token-2022 mints and rejects unsupported mint extensions", async () => {
    for (const extension of [ExtensionType.TransferFeeConfig, ExtensionType.TransferHook]) {
      await setInputMint(await createExtendedMint(extension), TOKEN_2022_PROGRAM_ID, true);
      await expectError(execute(encodeDeposit(deposit, { literal: true })), "UnsupportedTokenExtension");
    }

    await setInputMint(
      await createMint(connection, payer, owner, owner, 6, undefined, undefined, TOKEN_2022_PROGRAM_ID),
      TOKEN_2022_PROGRAM_ID,
      true
    );
    await execute(encodeDeposit(deposit, { literal: true }));
    assert.equal((await getAccount(connection, gatewayVault, undefined, tokenProgram)).amount, 500_000n);
    assert.equal((await getAccount(connection, spokeVault, undefined, tokenProgram)).amount, 500_000n);
  });

  it("binds JIT authorization to Gateway domain, path, and deposit nonce", async () => {
    const improvedOutput = bytes32(475_000);
    const newRelayer = Keypair.generate().publicKey;
    const rules = {
      authority: Buffer.from(jitSigner.address.slice(2), "hex"),
      output: true,
      relayer: true,
    };
    const input = encodeDeposit(deposit, { literal: true }, rules);
    const wrongPath = { ...context, pathId: Buffer.alloc(32, 0xcc) };
    await expectError(
      execute(input, signJit(jitSigner, wrongPath, deposit.depositNonce, improvedOutput, newRelayer)),
      "InvalidParamModificationSignature"
    );
    await expectError(
      execute(input, signJit(jitSigner, context, deposit.depositNonce + 1n, improvedOutput, newRelayer)),
      "InvalidParamModificationSignature"
    );
    await expectError(
      execute(
        input,
        signJit(jitSigner, context, deposit.depositNonce, improvedOutput, newRelayer, Keypair.generate().publicKey)
      ),
      "InvalidParamModificationSignature"
    );
  });

  it("rolls approval, transfer, and event state back when the continuing transaction fails", async () => {
    const input = encodeDeposit(deposit, { literal: true });
    await expectError(execute(input, Buffer.alloc(0), 1_000_000n, true), "ForcedFailure");
    const source = await getAccount(connection, gatewayVault);
    assert.equal(source.amount, 1_000_000n);
    assert.isNull(source.delegate);
    assert.equal((await getAccount(connection, spokeVault)).amount, 0n);
  });
});
