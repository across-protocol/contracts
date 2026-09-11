import "./provider";
import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  approveChecked,
  createMint,
  getAccount,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import {
  AccountMeta,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { assert } from "chai";
import { createHash, randomBytes } from "crypto";
import { calculateRelayHashUint8Array, processEventFromTx, readEventsUntilFound } from "../../src/svm/web3-v1";
import { RelayData } from "../../src/types/svm";
import { common } from "../svm/SvmSpoke.common";
import {
  GATEWAY,
  PREFUNDED,
  PREFIX,
  OP,
  Command,
  Deposit,
  Meta,
  Path,
  approve,
  assertAggregateDelivery,
  call,
  canonicalInPlace,
  depositInput,
  discriminator,
  executeParams,
  fillInput,
  fillJit,
  floor,
  funding,
  hash,
  injected,
  meta,
  pair,
  pathId,
  pda,
  tape,
  transfer,
  u32,
  u64,
  vec,
  word,
} from "./reference";

describe("SVM V5 with the pinned real Gateway", () => {
  anchor.setProvider(common.provider);
  const { provider, connection, owner, program: spoke, initializeState, chainId, setCurrentTime } = common;
  const wallet = (provider.wallet as anchor.Wallet).payer;
  const depositor = Keypair.generate();
  const writable = (pubkey: PublicKey): AccountMeta => ({ pubkey, isWritable: true, isSigner: false });
  const readonly = (pubkey: PublicKey): AccountMeta => ({ pubkey, isWritable: false, isSigner: false });
  const vaultAuthority = pda(GATEWAY, Buffer.from("vault_authority"));
  const gatewayConfig = pda(GATEWAY, Buffer.from("config"));
  const gatewayEvent = pda(GATEWAY, Buffer.from("__event_authority"));
  const dispatch = pda(GATEWAY, Buffer.from("dispatch_authority"), spoke.programId.toBuffer());
  const event = pda(spoke.programId, Buffer.from("__event_authority"));
  const sourceDelegate = pda(spoke.programId, Buffer.from("v5_source_delegate"));
  const fillDelegate = pda(spoke.programId, Buffer.from("v5_fill_delegate"));
  const fillPayer = pda(spoke.programId, Buffer.from("v5_fill_payer"), owner.toBuffer());
  const prefundedConfig = pda(PREFUNDED, Buffer.from("config"));
  const prefundedAuthority = pda(PREFUNDED, Buffer.from("authority"));
  const prefundedDispatch = pda(GATEWAY, Buffer.from("dispatch_authority"), PREFUNDED.toBuffer());
  const loader = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
  const amount = 500_000n;
  let state: PublicKey,
    mint: PublicKey,
    vault: PublicKey,
    spokeVault: PublicKey,
    userAta: PublicKey,
    depositAta: PublicKey;
  let recipient: PublicKey, recipientAta: PublicKey, now: number;
  const ix = (programId: PublicKey, name: string, data: Buffer, keys: AccountMeta[]) =>
    new TransactionInstruction({ programId, keys, data: Buffer.concat([discriminator(name), data]) });
  const send = (...instructions: TransactionInstruction[]) =>
    provider.sendAndConfirm(new Transaction().add(...instructions));
  const status = (relay: RelayData) =>
    pda(spoke.programId, Buffer.from("fills"), Buffer.from(calculateRelayHashUint8Array(relay, chainId)));
  const path = (commands: Command[], salt = randomBytes(32)): Path => ({
    chainId: BigInt(chainId.toString()),
    salt,
    message: tape(commands),
  });
  const baseMetas = () => [meta(state), meta(event), meta(spoke.programId)];
  const sourceMetas = () => [
    ...baseMetas(),
    meta(mint),
    meta(TOKEN_PROGRAM_ID),
    meta(vault, true),
    meta(spokeVault, true),
    meta(sourceDelegate),
  ];
  const fillMetas = (inPlace: boolean): Meta[] => [
    ...baseMetas(),
    meta(mint),
    meta(TOKEN_PROGRAM_ID),
    meta(vault, true),
    ...(!inPlace ? [meta(recipientAta, true), meta(fillDelegate)] : []),
    injected(),
    injected(),
    meta(SystemProgram.programId),
  ];
  const fillCommand = (inPlace = true, metas = fillMetas(inPlace)): Command => ({
    op: OP.ADAPTER_CALL | OP.JIT,
    input: call(spoke.programId, metas, fillInput(inPlace ? vaultAuthority : recipient, mint, amount)),
  });
  const destination = (inPlace = true): Path =>
    path(
      inPlace
        ? canonicalInPlace(fillCommand(), mint, amount, recipient)
        : [approve(mint, fillDelegate), fillCommand(false)]
    );
  const remaining = (relays: RelayData[] = []): AccountMeta[] => [
    readonly(spoke.programId),
    readonly(dispatch),
    readonly(state),
    readonly(event),
    readonly(mint),
    readonly(TOKEN_PROGRAM_ID),
    writable(vault),
    writable(spokeVault),
    writable(userAta),
    writable(recipientAta),
    readonly(vaultAuthority),
    readonly(sourceDelegate),
    readonly(fillDelegate),
    writable(fillPayer),
    readonly(SystemProgram.programId),
    ...relays.map((r) => writable(status(r))),
  ];
  const relayJit = (r: RelayData, claimedStatus = status(r), claimedPayer = fillPayer) =>
    Buffer.concat([claimedStatus.toBuffer(), claimedPayer.toBuffer(), fillJit(r, owner)]);

  // Tapes contain full account keys in instruction data, so even a LUT cannot
  // make them fit. Use the Gateway's content-addressed parameter buffer.
  async function execute(
    p: Path,
    opts: {
      relays?: RelayData[];
      root?: Buffer;
      proof?: Buffer[];
      jit?: Buffer[];
      funds?: Buffer[];
      extra?: AccountMeta[];
      accounts?: AccountMeta[];
      failed?: boolean;
    } = {}
  ) {
    const relays = opts.relays ?? [];
    const bytes = executeParams(
      p,
      opts.root ?? pathId(p),
      opts.proof ?? [],
      opts.jit ?? relays.map((r) => relayJit(r)),
      opts.funds ?? []
    );
    const accountDiscriminator = createHash("sha256").update("account:ExecuteParamsAccount").digest().subarray(0, 8);
    const digest = createHash("sha256")
      .update(Buffer.concat([accountDiscriminator, bytes]))
      .digest();
    const buffer = pda(GATEWAY, Buffer.from("execute_params"), owner.toBuffer(), digest);
    try {
      await send(
        ix(GATEWAY, "initialize_execute_params", Buffer.concat([digest, u32(bytes.length)]), [
          { ...writable(owner), isSigner: true },
          writable(buffer),
          readonly(SystemProgram.programId),
        ])
      );
      for (let offset = 0; offset < bytes.length; offset += 800) {
        await send(
          ix(
            GATEWAY,
            "write_execute_params_fragment",
            Buffer.concat([digest, u32(offset), vec(bytes.subarray(offset, offset + 800))]),
            [{ ...readonly(owner), isSigner: true }, writable(buffer)]
          )
        );
      }
      const instruction = ix(GATEWAY, "execute", Buffer.from([0]), [
        { ...readonly(owner), isSigner: true },
        { ...writable(owner), isSigner: true },
        writable(buffer),
        readonly(gatewayConfig),
        readonly(gatewayEvent),
        readonly(GATEWAY),
        ...(opts.accounts ?? remaining(relays)),
        ...(opts.extra ?? []),
      ]);
      if (opts.failed) {
        const tx = new Transaction().add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), instruction);
        tx.feePayer = owner;
        tx.recentBlockhash = (await connection.getLatestBlockhash()).blockhash;
        tx.sign(wallet);
        const signature = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: true });
        await connection.confirmTransaction(signature, "confirmed");
        let receipt = await connection.getTransaction(signature, {
          commitment: "confirmed",
          maxSupportedTransactionVersion: 0,
        });
        for (let n = 0; !receipt && n < 30; n++) {
          await new Promise((resolve) => setTimeout(resolve, 100));
          receipt = await connection.getTransaction(signature, {
            commitment: "confirmed",
            maxSupportedTransactionVersion: 0,
          });
        }
        assert.isNotNull(receipt);
        assert.isNotNull(receipt!.meta!.err, "must be a failed transaction, never an accepted fill event");
        return {
          signature,
          failedReceipt: {
            logs: receipt!.meta!.logMessages ?? [],
            attemptedEvents: processEventFromTx(receipt!, [spoke]),
          },
        };
      }
      const signature = await send(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), instruction);
      assert.isNull(await connection.getAccountInfo(buffer), "successful execution closes parameter buffer");
      return { signature };
    } finally {
      if (await connection.getAccountInfo(buffer))
        await send(
          ix(GATEWAY, "close_execute_params", digest, [{ ...writable(owner), isSigner: true }, writable(buffer)])
        );
    }
  }
  async function expectFailure(p: Promise<unknown>, name: string) {
    let error: unknown;
    try {
      await p;
    } catch (e) {
      error = e;
    }
    assert.isDefined(error, `expected ${name}`);
    assert.include(String(error), name);
  }
  async function fund(amountToFund: bigint = amount) {
    await mintTo(connection, wallet, mint, vault, wallet, amountToFund);
  }
  async function filled(r: RelayData) {
    const account = await spoke.account.fillStatusAccount.fetch(status(r));
    assert.hasAnyKeys(account.status, ["filled"]);
    assert.equal(account.relayer.toBase58(), fillPayer.toBase58());
  }
  async function origin(root: Buffer, inPlace = true, prefunded = false, outputAmount = amount): Promise<RelayData> {
    const d: Deposit = {
      depositor: depositor.publicKey,
      recipient: inPlace ? vaultAuthority : recipient,
      inputToken: mint,
      outputToken: mint,
      inputAmount: amount,
      outputAmount,
      destinationChainId: BigInt(chainId.toString()),
      nonce: BigInt(`0x${randomBytes(8).toString("hex")}`),
      quoteTimestamp: now,
      fillDeadline: now + 600,
      dstStepId: root,
    };
    const deposit: Command = { op: OP.ADAPTER_CALL, input: call(spoke.programId, sourceMetas(), depositInput(d)) };
    const commands = [approve(mint, sourceDelegate), deposit];
    const extra: AccountMeta[] = [];
    let jit: Buffer[] = [],
      funds: Buffer[] = [];
    if (prefunded)
      commands.unshift({
        op: OP.ADAPTER_CALL | OP.JIT,
        input: call(
          PREFUNDED,
          [
            meta(prefundedConfig),
            meta(mint),
            meta(TOKEN_PROGRAM_ID),
            meta(prefundedAuthority),
            injected(),
            injected(),
            meta(vault, true),
          ],
          Buffer.concat([mint.toBuffer(), u64(amount), vaultAuthority.toBuffer()])
        ),
      });
    const source = path(commands);
    const rootSource = pathId(source);
    if (prefunded) {
      const credit = pda(PREFUNDED, Buffer.from("credit"), rootSource, mint.toBuffer(), owner.toBuffer());
      await send(
        ix(PREFUNDED, "store", Buffer.concat([rootSource, u64(amount)]), [
          { ...readonly(owner), isSigner: true },
          writable(owner),
          readonly(prefundedAuthority),
          readonly(mint),
          writable(userAta),
          writable(credit),
          readonly(TOKEN_PROGRAM_ID),
          readonly(SystemProgram.programId),
          readonly(pda(PREFUNDED, Buffer.from("__event_authority"))),
          readonly(PREFUNDED),
        ])
      );
      jit = [Buffer.concat([credit.toBuffer(), owner.toBuffer(), owner.toBuffer()])];
      extra.push(
        readonly(PREFUNDED),
        readonly(prefundedConfig),
        readonly(prefundedAuthority),
        readonly(prefundedDispatch),
        writable(credit),
        writable(owner)
      );
    } else {
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const delegate = pda(GATEWAY, Buffer.from("step_funding"), rootSource, mint.toBuffer(), u64(deadline));
      await approveChecked(connection, wallet, mint, depositAta, delegate, depositor, amount, 6);
      funds = [funding(depositAta, mint, amount, deadline)];
      extra.push(readonly(delegate), writable(depositAta));
    }
    const before = (await getAccount(connection, spokeVault)).amount;
    const { signature } = await execute(source, { funds, jit, extra });
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.equal((await getAccount(connection, spokeVault)).amount - before, amount);
    if (!prefunded)
      assert.isNull(
        (await getAccount(connection, depositAta)).delegate,
        "one-shot StepDelegate consumed without the depositor co-signing execution"
      );
    else
      assert.isNull(
        await connection.getAccountInfo(
          pda(PREFUNDED, Buffer.from("credit"), rootSource, mint.toBuffer(), owner.toBuffer())
        ),
        "prefunded credit closes after release"
      );
    const deposited = (await readEventsUntilFound(connection, signature, [spoke])).find(
      (e) => e.name === "fundsDeposited"
    )!.data;
    assert.deepEqual(Buffer.from(deposited.message), Buffer.concat([PREFIX, root]));
    const expectedId = hash(
      Buffer.concat([
        GATEWAY.toBuffer(),
        depositor.publicKey.toBuffer(),
        hash(Buffer.concat([owner.toBuffer(), pathId(source), word(d.nonce)])),
      ])
    );
    assert.deepEqual(Buffer.from(deposited.depositId), expectedId);
    return {
      depositor: deposited.depositor,
      recipient: deposited.recipient,
      exclusiveRelayer: deposited.exclusiveRelayer,
      inputToken: deposited.inputToken,
      outputToken: deposited.outputToken,
      inputAmount: [...word(BigInt(deposited.inputAmount.toString()))],
      outputAmount: new BN(Buffer.from(deposited.outputAmount), "be"),
      originChainId: chainId,
      depositId: deposited.depositId,
      fillDeadline: deposited.fillDeadline,
      exclusivityDeadline: deposited.exclusivityDeadline,
      message: Buffer.from(deposited.message),
    };
  }
  before(async () => {
    for (const [programId, config, data] of [
      [GATEWAY, gatewayConfig, u64(chainId)],
      [PREFUNDED, prefundedConfig, Buffer.concat([GATEWAY.toBuffer(), owner.toBuffer()])],
    ] as [PublicKey, PublicKey, Buffer][])
      await send(
        ix(programId, "initialize", data, [
          { ...writable(owner), isSigner: true },
          writable(config),
          readonly(programId),
          readonly(pda(loader, programId.toBuffer())),
          readonly(SystemProgram.programId),
        ])
      );
  });
  beforeEach(async () => {
    ({ state } = await initializeState());
    now = (await spoke.account.state.fetch(state)).currentTime;
    mint = await createMint(connection, wallet, owner, null, 6);
    recipient = Keypair.generate().publicKey;
    const ata = async (who: PublicKey) =>
      (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, who, true)).address;
    [vault, spokeVault, userAta, recipientAta, depositAta] = await Promise.all([
      ata(vaultAuthority),
      ata(state),
      ata(owner),
      ata(recipient),
      ata(depositor.publicKey),
    ]);
    await mintTo(connection, wallet, mint, userAta, wallet, amount * 10n);
    await mintTo(connection, wallet, mint, depositAta, wallet, amount * 10n);
    await send(SystemProgram.transfer({ fromPubkey: owner, toPubkey: fillPayer, lamports: 10_000_000 }));
  });

  it("cleans parameter buffers after setup errors so byte-identical executions can retry", async () => {
    for (const failAfter of ["initialize_execute_params", "write_execute_params_fragment"]) {
      const dst = path([floor(mint, 0n)]);
      const originalSend = provider.sendAndConfirm;
      provider.sendAndConfirm = async (tx, ...args) => {
        const signature = await originalSend.call(provider, tx, ...args);
        if (
          tx instanceof Transaction &&
          tx.instructions.some(
            (ix) => ix.programId.equals(GATEWAY) && ix.data.subarray(0, 8).equals(discriminator(failAfter))
          )
        )
          throw new Error("injected setup confirmation failure");
        return signature;
      };
      try {
        await expectFailure(execute(dst), "injected setup confirmation failure");
      } finally {
        provider.sendAndConfirm = originalSend;
      }
      await execute(dst);
    }
  });
  it("StepDelegate origin binds the destination root; external fill delivers exactly and reclaims payer rent", async () => {
    const dst = destination(false);
    const relay = await origin(pathId(dst), false);
    await fund();
    const payerBefore = await connection.getBalance(fillPayer);
    const result = await execute(dst, { relays: [relay] });
    assert.notProperty(result, "failedReceipt", "successful execution does not return placeholder diagnostics");
    const { signature } = result;
    await filled(relay);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.equal((await getAccount(connection, recipientAta)).amount, amount);
    const events = await readEventsUntilFound(connection, signature, [spoke]);
    assert.equal(events.filter((e) => e.name === "filledRelay").length, 1);
    const rent = (await connection.getAccountInfo(status(relay)))!.lamports;
    assert.equal(await connection.getBalance(fillPayer), payerBefore - rent);
    await setCurrentTime(spoke, state, Keypair.generate(), new BN(relay.fillDeadline + 1));
    await spoke.methods
      .closeFillPda()
      .accountsPartial({ state, signer: fillPayer, fillStatus: status(relay) })
      .rpc();
    assert.equal(await connection.getBalance(fillPayer), payerBefore);
    await spoke.methods
      .withdrawV5FillPayer(new BN("18446744073709551615"))
      .accountsPartial({ submitter: owner, payer: fillPayer })
      .rpc();
    assert.equal(await connection.getBalance(fillPayer), 0);
  });
  it("prefunded origin composes with in-place fill and full-balance consumption", async () => {
    const dst = destination();
    const relay = await origin(pathId(dst), true, true);
    await fund(amount + 123n);
    await execute(dst, { relays: [relay] });
    await filled(relay);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.equal((await getAccount(connection, recipientAta)).amount, amount + 123n);
    assert.isNull((await getAccount(connection, vault)).delegate, "in-place delivery never approves");
  });
  it("rejects a relay committed to another destination step without spending the payer", async () => {
    const relay = await origin(pathId(destination()));
    const dst = destination();
    await fund();
    const before = await connection.getBalance(fillPayer);
    await expectFailure(execute(dst, { relays: [relay] }), "FillCommitmentMismatch");
    assert.isNull(await connection.getAccountInfo(status(relay)));
    assert.equal(await connection.getBalance(fillPayer), before);
  });
  it("requires live dispatch and prevents another submitter withdrawing the fill payer", async () => {
    const dst = destination();
    const relay = await origin(pathId(dst));
    await expectFailure(
      send(
        ix(
          spoke.programId,
          "adapter_execute_across_v5",
          Buffer.concat([
            pathId(dst),
            pathId(dst),
            owner.toBuffer(),
            vec(fillInput(vaultAuthority, mint, amount)),
            vec(fillJit(relay, owner)),
          ]),
          [readonly(dispatch), readonly(state), readonly(event), readonly(spoke.programId), ...remaining([relay])]
        )
      ),
      "InvalidDispatchAuthority"
    );
    const stranger = Keypair.generate();
    await send(SystemProgram.transfer({ fromPubkey: owner, toPubkey: stranger.publicKey, lamports: 1_000_000 }));
    await expectFailure(
      spoke.methods
        .withdrawV5FillPayer(new BN(1))
        .accountsPartial({ submitter: stranger.publicKey, payer: fillPayer })
        .signers([stranger])
        .rpc(),
      "ConstraintSeeds"
    );
    assert.isNull(await connection.getAccountInfo(status(relay)));
  });
  it("sibling leaves share replay status; either sibling may win and the other rolls back", async () => {
    const a = destination(),
      b = destination();
    const root = pair(pathId(a), pathId(b));
    for (const [first, other] of [
      [a, b],
      [b, a],
    ]) {
      const relay = await origin(root);
      await fund();
      await execute(first, { root, proof: [pathId(other)], relays: [relay] });
      const fundingBefore = (await getAccount(connection, userAta)).amount;
      for (const [retry, sibling] of [
        [first, other],
        [other, first],
      ]) {
        await expectFailure(
          execute(retry, { root, proof: [pathId(sibling)], relays: [relay], funds: [funding(userAta, mint, amount)] }),
          "RelayFilled"
        );
        assert.equal((await getAccount(connection, userAta)).amount, fundingBefore);
      }
      await filled(relay);
      assert.equal((await getAccount(connection, vault)).amount, 0n);
    }
    assert.equal((await getAccount(connection, recipientAta)).amount, amount * 2n);
  });
  it("reuses one destination root for separately funded source deposits and executions", async () => {
    const dst = destination();
    const relays = [await origin(pathId(dst)), await origin(pathId(dst))];
    assert.notDeepEqual(relays[0].depositId, relays[1].depositId);
    for (const relay of relays) {
      await fund();
      await execute(dst, { relays: [relay] });
      await filled(relay);
      assert.equal((await getAccount(connection, vault)).amount, 0n);
    }
    assertAggregateDelivery(
      relays.map((r) => BigInt(r.outputAmount.toString())),
      (await getAccount(connection, recipientAta)).amount
    );
  });
  it("rolls back recorded fills, emitted event effects, tokens and rent after a downstream failure", async () => {
    const dst = path([...canonicalInPlace(fillCommand(), mint, amount, recipient), floor(mint, 1n)]);
    const relay = await origin(pathId(dst));
    const userBefore = (await getAccount(connection, userAta)).amount;
    const payerBefore = await connection.getBalance(fillPayer);
    const { failedReceipt } = await execute(dst, {
      relays: [relay],
      funds: [funding(userAta, mint, amount)],
      failed: true,
    });
    if (!failedReceipt) assert.fail("expected failed transaction diagnostics");
    assert.include(
      failedReceipt.logs.join("\n"),
      `Program ${spoke.programId} success`,
      "fill completed before failure"
    );
    assert.include(failedReceipt.logs.join("\n"), "BalanceRequirementNotMet");
    const attemptedFills = failedReceipt.attemptedEvents.filter((e) => e.name === "filledRelay");
    assert.lengthOf(attemptedFills, 1, "failed receipt still contains the attempted FilledRelay CPI event");
    assert.deepEqual(Buffer.from(attemptedFills[0].data.depositId), Buffer.from(relay.depositId));
    assert.isNull(await connection.getAccountInfo(status(relay)));
    assert.equal(await connection.getBalance(fillPayer), payerBefore);
    assert.equal((await getAccount(connection, userAta)).amount, userBefore);
    assert.equal((await getAccount(connection, recipientAta)).amount, 0n);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
  });
  it("rejects signer/dispatch metas, unauthenticated dynamic accounts, omitted metas and malformed JIT", async () => {
    const invalidMetas = [
      { metas: [...fillMetas(true), { pubkey: owner, flags: 2 }], error: "SignerNotAllowed" },
      { metas: [...fillMetas(true), meta(dispatch)], error: "DispatchAuthorityMetaNotAllowed" },
      { metas: fillMetas(true).filter((m) => !m.pubkey.equals(mint)), error: "MissingAccount" },
    ];
    for (const { metas, error } of invalidMetas) {
      const dst = path(canonicalInPlace(fillCommand(true, metas), mint, amount, recipient));
      const relay = await origin(pathId(dst));
      await expectFailure(execute(dst, { relays: [relay] }), error);
      assert.isNull(await connection.getAccountInfo(status(relay)));
    }
    const dst = destination();
    const relay = await origin(pathId(dst));
    const wrong = Keypair.generate().publicKey;
    await fund();
    for (const jit of [relayJit(relay, wrong), relayJit(relay, status(relay), wrong)]) {
      await expectFailure(execute(dst, { relays: [relay], jit: [jit], extra: [writable(wrong)] }), "MissingAccount");
      assert.isNull(await connection.getAccountInfo(status(relay)));
    }
    await expectFailure(execute(dst, { relays: [relay], jit: [Buffer.alloc(31)] }), "InjectedAccountsMismatch");
    assert.isNull(await connection.getAccountInfo(status(relay)));
  });
  it("rejects an optional downstream command and rolls back an already executed fill", async () => {
    const optional = transfer(mint, recipient);
    optional.op |= OP.OPTIONAL;
    const dst = path([fillCommand(), optional]);
    const relay = await origin(pathId(dst));
    await fund();
    await expectFailure(execute(dst, { relays: [relay] }), "AllowRevertUnsupported");
    assert.isNull(await connection.getAccountInfo(status(relay)));
    assert.equal((await getAccount(connection, recipientAta)).amount, 0n);
    assert.equal((await getAccount(connection, vault)).amount, amount);
  });
  it("pins accepted short and missing consumption as unsafe builder counterexamples", async () => {
    // These accepted primitive behaviors are NOT route safety guarantees.
    for (const consumed of [0n, amount - 1n]) {
      const dst = path([
        fillCommand(),
        floor(mint, amount),
        ...(consumed ? [transfer(mint, recipient, consumed)] : []),
      ]);
      const relay = await origin(pathId(dst));
      await fund();
      const before = (await getAccount(connection, recipientAta)).amount;
      await execute(dst, { relays: [relay] });
      await filled(relay);
      const delivered = (await getAccount(connection, recipientAta)).amount - before;
      assert.equal(delivered, consumed);
      assert.throws(() => assertAggregateDelivery([amount], delivered), "aggregate underdelivery");
      // Explicitly clean this deliberately unsafe fixture before the next origin.
      await execute(path([transfer(mint, recipient)]));
    }
  });
  it("two distinct fills can observe one balance; a fixed min-X floor and full drain cover only X", async () => {
    const dst = path([fillCommand(), fillCommand(), floor(mint, amount), transfer(mint, recipient)]);
    const relays = [await origin(pathId(dst)), await origin(pathId(dst))];
    await fund();
    await execute(dst, { relays });
    for (const relay of relays) await filled(relay);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.equal((await getAccount(connection, recipientAta)).amount, amount);
    assert.throws(() => assertAggregateDelivery([amount, amount], amount), "aggregate underdelivery");
  });
  it("a cumulative floor rolls every fill back when short, then covers a concrete aggregate execution", async () => {
    const dst = path([fillCommand(), fillCommand(), floor(mint, amount * 2n), transfer(mint, recipient)]);
    const relays = [await origin(pathId(dst)), await origin(pathId(dst))];
    const payerBefore = await connection.getBalance(fillPayer);
    await fund();
    await expectFailure(execute(dst, { relays }), "BalanceRequirementNotMet");
    for (const relay of relays) assert.isNull(await connection.getAccountInfo(status(relay)));
    assert.equal(await connection.getBalance(fillPayer), payerBefore);
    await fund();
    await execute(dst, { relays });
    for (const relay of relays) await filled(relay);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assertAggregateDelivery([amount, amount], (await getAccount(connection, recipientAta)).amount);
  });
  it("a floor summing committed minima is still unsafe when allowed JIT amounts are larger", async () => {
    const dst = path([fillCommand(), fillCommand(), floor(mint, amount * 2n), transfer(mint, recipient)]);
    const relays = [
      await origin(pathId(dst), true, false, amount * 2n),
      await origin(pathId(dst), true, false, amount * 2n),
    ];
    // Actual source deposits with larger output obligations. The V5
    // fill primitive accepts both under the same min-X input; a safe builder
    // must prove all permissible relay substitutions, not only its sample Xs.
    await fund(amount * 2n);
    await execute(dst, { relays });
    for (const relay of relays) await filled(relay);
    const delivered = (await getAccount(connection, recipientAta)).amount;
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.equal(delivered, amount * 2n);
    assert.throws(() => assertAggregateDelivery([amount * 2n, amount * 2n], delivered), "aggregate underdelivery");
  });
});
