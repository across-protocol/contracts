import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { TOKEN_PROGRAM_ID, createMint, getAccount, getOrCreateAssociatedTokenAccount, mintTo } from "@solana/spl-token";
import { AccountMeta, Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction } from "@solana/web3.js";
import { assert } from "chai";
import { createHash, randomBytes } from "crypto";
import { ethers } from "ethers";
import { calculateRelayHashUint8Array, hashNonEmptyMessage, readEventsUntilFound } from "../../src/svm/web3-v1";
import { RelayData } from "../../src/types/svm";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { common } from "./SvmSpoke.common";

const GATEWAY = new PublicKey("34trBszXuqhRjWaMxXWsunJNmyUsBvDNPxAwTzbPTm4p");
const V5_PREFIX = Buffer.from("89ae4bc75915265a3f10e926c3894a29534f1d6362ee8959cb0e5be00f3527fd", "hex");
const mockDiscriminator = createHash("sha256").update("global:execute_fill_adapter").digest().subarray(0, 8);
const u32 = (value: number) => {
  const data = Buffer.alloc(4);
  data.writeUInt32LE(value);
  return data;
};
const u64 = (value: bigint | number | BN) => {
  const data = Buffer.alloc(8);
  data.writeBigUInt64LE(BigInt(value.toString()));
  return data;
};
const vec = (value: Buffer) => Buffer.concat([u32(value.length), value]);
const encodeContext = (stepId: Buffer, pathId: Buffer, submitter: PublicKey) =>
  Buffer.concat([stepId, pathId, submitter.toBuffer()]);
const encodeFill = (recipient: PublicKey, outputToken: PublicKey, minOutputAmount: bigint, message = Buffer.alloc(0)) =>
  Buffer.concat([
    Buffer.from([1, 1]),
    recipient.toBuffer(),
    outputToken.toBuffer(),
    u64(minOutputAmount),
    vec(message),
  ]);
const encodeRelay = (relay: RelayData) =>
  Buffer.concat([
    relay.depositor.toBuffer(),
    relay.recipient.toBuffer(),
    relay.exclusiveRelayer.toBuffer(),
    relay.inputToken.toBuffer(),
    relay.outputToken.toBuffer(),
    Buffer.from(relay.inputAmount),
    u64(relay.outputAmount),
    u64(relay.originChainId),
    Buffer.from(relay.depositId),
    u32(relay.fillDeadline),
    u32(relay.exclusivityDeadline),
    vec(relay.message),
  ]);
const encodeJit = (relay: RelayData, repaymentChainId: BN, repaymentAddress: PublicKey) =>
  Buffer.concat([encodeRelay(relay), u64(repaymentChainId), repaymentAddress.toBuffer()]);

describe("svm_spoke V5 destination fill", () => {
  anchor.setProvider(common.provider);
  const { connection, owner, provider, chainId, initializeState, program, setCurrentTime } = common;
  const svmSpoke = program as Program<SvmSpoke>;
  const wallet = (provider.wallet as anchor.Wallet).payer;
  const [vaultAuthority] = PublicKey.findProgramAddressSync([Buffer.from("vault_authority")], GATEWAY);
  const [dispatchAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("dispatch_authority"), svmSpoke.programId.toBuffer()],
    GATEWAY
  );
  const [fillDelegate] = PublicKey.findProgramAddressSync([Buffer.from("v5_fill_delegate")], svmSpoke.programId);
  const [fillPayer] = PublicKey.findProgramAddressSync(
    [Buffer.from("v5_fill_payer"), owner.toBuffer()],
    svmSpoke.programId
  );
  const [eventAuthority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], svmSpoke.programId);
  const stepId = Buffer.alloc(32, 0xa5);
  const pathId = Buffer.alloc(32, 0xb6);
  const outputAmount = 500_000n;

  let state: PublicKey;
  let mint: PublicKey;
  let gatewayVault: PublicKey;
  let recipient: PublicKey;
  let recipientToken: PublicKey;
  let consumptionAccount: PublicKey;
  let relay: RelayData;

  const relayHash = (value = relay) => Buffer.from(calculateRelayHashUint8Array(value, chainId));
  const fillStatus = (value = relay) =>
    PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash(value)], svmSpoke.programId)[0];

  const instruction = (
    input: Buffer,
    jit: Buffer,
    options: {
      approval?: bigint | null;
      consume?: bigint;
      failAfter?: boolean;
      recipientAccount?: PublicKey;
      delegate?: PublicKey;
      payer?: PublicKey;
      status?: PublicKey;
    } = {}
  ) => {
    const approval = options.approval === undefined ? 750_000n : options.approval;
    const keys: AccountMeta[] = [
      { pubkey: owner, isSigner: true, isWritable: false },
      { pubkey: vaultAuthority, isSigner: false, isWritable: false },
      { pubkey: dispatchAuthority, isSigner: false, isWritable: false },
      { pubkey: gatewayVault, isSigner: false, isWritable: true },
      { pubkey: options.recipientAccount ?? recipientToken, isSigner: false, isWritable: true },
      { pubkey: consumptionAccount, isSigner: false, isWritable: true },
      { pubkey: mint, isSigner: false, isWritable: false },
      { pubkey: options.delegate ?? fillDelegate, isSigner: false, isWritable: false },
      { pubkey: options.payer ?? fillPayer, isSigner: false, isWritable: true },
      { pubkey: options.status ?? fillStatus(), isSigner: false, isWritable: true },
      { pubkey: state, isSigner: false, isWritable: false },
      { pubkey: eventAuthority, isSigner: false, isWritable: false },
      { pubkey: TOKEN_PROGRAM_ID, isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      { pubkey: svmSpoke.programId, isSigner: false, isWritable: false },
    ];
    const encodedApproval = approval === null ? Buffer.from([0]) : Buffer.concat([Buffer.from([1]), u64(approval)]);
    return new TransactionInstruction({
      programId: GATEWAY,
      keys,
      data: Buffer.concat([
        mockDiscriminator,
        encodeContext(stepId, pathId, owner),
        vec(input),
        vec(jit),
        encodedApproval,
        u64(options.consume ?? 0n),
        Buffer.from([Number(options.failAfter ?? false)]),
      ]),
    });
  };

  const execute = (
    input = encodeFill(recipient, mint, outputAmount),
    jit = encodeJit(relay, new BN(777), Keypair.generate().publicKey),
    options: Parameters<typeof instruction>[2] = {}
  ) => provider.sendAndConfirm(new Transaction().add(instruction(input, jit, options)));

  const expectError = async (promise: Promise<unknown>, name: string) => {
    try {
      await promise;
      assert.fail(`Expected ${name}`);
    } catch (error: any) {
      const text = [error.toString(), ...(error.logs ?? [])].join("\n");
      if (!text.includes(name)) throw new Error(text);
    }
  };

  beforeEach(async () => {
    ({ state } = await initializeState());
    mint = await createMint(connection, wallet, owner, owner, 6);
    gatewayVault = (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, vaultAuthority, true)).address;
    recipient = Keypair.generate().publicKey;
    recipientToken = (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, recipient, true)).address;
    consumptionAccount = (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, owner)).address;
    await mintTo(connection, wallet, mint, gatewayVault, owner, outputAmount);

    const now = (await svmSpoke.account.state.fetch(state)).currentTime;
    relay = {
      depositor: Keypair.generate().publicKey,
      recipient,
      exclusiveRelayer: owner,
      inputToken: Keypair.generate().publicKey,
      outputToken: mint,
      inputAmount: [...randomBytes(32)],
      outputAmount: new BN(outputAmount.toString()),
      originChainId: new BN(1),
      depositId: [...randomBytes(32)],
      fillDeadline: now + 600,
      exclusivityDeadline: now + 300,
      message: Buffer.concat([V5_PREFIX, stepId]),
    };

    await provider.sendAndConfirm(
      new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: owner,
          toPubkey: fillPayer,
          lamports: await connection.getMinimumBalanceForRentExemption(45),
        })
      )
    );
  });

  it("pulls exactly to an external ATA, records replay state, emits the standard event, and reclaims rent", async () => {
    const repaymentAddress = Keypair.generate().publicKey;
    const signature = await execute(
      encodeFill(recipient, mint, outputAmount),
      encodeJit(relay, new BN(777), repaymentAddress)
    );

    assert.equal((await getAccount(connection, gatewayVault)).amount, 0n);
    assert.equal((await getAccount(connection, recipientToken)).amount, outputAmount);
    const status = await svmSpoke.account.fillStatusAccount.fetch(fillStatus());
    assert.hasAnyKeys(status.status, ["filled"]);
    assert.equal(status.relayer.toBase58(), fillPayer.toBase58());
    assert.equal(status.fillDeadline, relay.fillDeadline);

    const event = (await readEventsUntilFound(connection, signature, [svmSpoke])).find(
      (value) => value.name === "filledRelay"
    )?.data;
    assert.isDefined(event);
    assert.equal(event.recipient.toBase58(), recipient.toBase58());
    assert.equal(event.outputToken.toBase58(), mint.toBase58());
    assert.equal(event.outputAmount.toString(), outputAmount.toString());
    assert.equal(event.repaymentChainId.toString(), "777");
    assert.equal(event.relayer.toBase58(), repaymentAddress.toBase58());
    assert.deepEqual([...event.messageHash], [...hashNonEmptyMessage(relay.message)]);
    assert.deepEqual([...event.relayExecutionInfo.updatedMessageHash], [...Buffer.alloc(32)]);
    assert.deepEqual(event.relayExecutionInfo.fillType, { fastFill: {} });

    await setCurrentTime(svmSpoke, state, Keypair.generate(), new BN(relay.fillDeadline + 1));
    await svmSpoke.methods.closeFillPda().accounts({ state, signer: fillPayer, fillStatus: fillStatus() }).rpc();
    assert.isNull(await connection.getAccountInfo(fillStatus()));
    assert.equal(await connection.getBalance(fillPayer), await connection.getMinimumBalanceForRentExemption(45));
  });

  it("rejects sibling competition, malformed commitments, expired and non-exclusive fills", async () => {
    await execute();
    await expectError(execute(undefined, encodeJit(relay, new BN(888), Keypair.generate().publicKey)), "RelayFilled");

    const fresh = { ...relay, depositId: [...randomBytes(32)] };
    relay = fresh;
    await expectError(execute(encodeFill(Keypair.generate().publicKey, mint, outputAmount)), "FillCommitmentMismatch");
    await expectError(
      execute(encodeFill(recipient, Keypair.generate().publicKey, outputAmount)),
      "FillCommitmentMismatch"
    );
    await expectError(execute(encodeFill(recipient, mint, outputAmount + 1n)), "FillOutputAmountTooLow");
    await expectError(execute(encodeFill(recipient, mint, outputAmount, Buffer.from([1]))), "InvalidWireFormat");

    relay = { ...fresh, message: Buffer.concat([V5_PREFIX, Buffer.alloc(32, 9)]) };
    await expectError(execute(), "FillCommitmentMismatch");
    relay = { ...fresh, exclusiveRelayer: Keypair.generate().publicKey };
    await expectError(execute(), "NotExclusiveRelayer");
    relay = { ...fresh, exclusiveRelayer: PublicKey.default, fillDeadline: 0, exclusivityDeadline: 0 };
    await expectError(execute(), "ExpiredFillDeadline");
  });

  it("rejects paused fills, wrong branch accounts, and insufficient allowance", async () => {
    await svmSpoke.methods.pauseFills(true).accounts({ state, signer: owner, program: svmSpoke.programId }).rpc();
    await expectError(execute(), "FillsArePaused");
    await svmSpoke.methods.pauseFills(false).accounts({ state, signer: owner, program: svmSpoke.programId }).rpc();

    await expectError(execute(undefined, undefined, { approval: outputAmount - 1n }), "InsufficientDelegateAllowance");
    await expectError(execute(undefined, undefined, { delegate: Keypair.generate().publicKey }), "InvalidTokenAccount");
    await expectError(execute(undefined, undefined, { payer: Keypair.generate().publicKey }), "MissingAccount");
    await expectError(execute(undefined, undefined, { status: Keypair.generate().publicKey }), "MissingAccount");
  });

  it("rolls approval, transfer, fill status, and payer debit back after a downstream failure", async () => {
    const payerBalance = await connection.getBalance(fillPayer);
    await expectError(execute(undefined, undefined, { failAfter: true }), "ForcedFailure");
    const source = await getAccount(connection, gatewayVault);
    assert.equal(source.amount, outputAmount);
    assert.isNull(source.delegate);
    assert.equal((await getAccount(connection, recipientToken)).amount, 0n);
    assert.isNull(await connection.getAccountInfo(fillStatus()));
    assert.equal(await connection.getBalance(fillPayer), payerBalance);
  });

  it("authenticates in-place Gateway-vault delivery and leaves the canonical path empty after consumption", async () => {
    relay = { ...relay, recipient: vaultAuthority };
    const signature = await execute(encodeFill(vaultAuthority, mint, outputAmount), undefined, {
      approval: null,
      consume: outputAmount,
      recipientAccount: gatewayVault,
    });
    assert.isString(signature);
    const source = await getAccount(connection, gatewayVault);
    assert.equal(source.amount, 0n);
    assert.isNull(source.delegate);
    assert.equal((await getAccount(connection, consumptionAccount)).amount, outputAmount);
    assert.hasAnyKeys((await svmSpoke.account.fillStatusAccount.fetch(fillStatus())).status, ["filled"]);
  });

  it("requires live vault balance for in-place delivery", async () => {
    relay = { ...relay, recipient: vaultAuthority, outputAmount: new BN((outputAmount + 1n).toString()) };
    await expectError(
      execute(encodeFill(vaultAuthority, mint, outputAmount), undefined, {
        approval: null,
        recipientAccount: gatewayVault,
      }),
      "InsufficientVaultBalance"
    );
    assert.isNull(await connection.getAccountInfo(fillStatus()));
  });
});
