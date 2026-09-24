import "./provider";
import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  NATIVE_MINT,
  ExtensionType,
  createReallocateInstruction,
  createEnableCpiGuardInstruction,
  createSyncNativeInstruction,
  createCloseAccountInstruction,
  getCpiGuard,
  getAssociatedTokenAddressSync,
  approveChecked,
  createMint,
  createAccount,
  getAccount,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import {
  AccountMeta,
  AddressLookupTableAccount,
  AddressLookupTableProgram,
  TransactionMessage,
  VersionedTransaction,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { address, createNoopSigner } from "@solana/kit";
import { SvmSpokeClient } from "../../src/svm/clients";
import { assert } from "chai";
import { createHash, randomBytes } from "crypto";
import { calculateRelayHashUint8Array, processEventFromTx, readEventsUntilFound } from "../../src/svm/web3-v1";
import { createSwapFixture, SWAP_PROGRAM } from "./swapFixture";
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
  let tokenProgram = TOKEN_PROGRAM_ID;
  let recipient: PublicKey, recipientAta: PublicKey, now: number;
  const ix = (programId: PublicKey, name: string, data: Buffer, keys: AccountMeta[]) =>
    new TransactionInstruction({ programId, keys, data: Buffer.concat([discriminator(name), data]) });
  async function sendTransaction(tx: Transaction | VersionedTransaction) {
    try {
      return await provider.sendAndConfirm(tx);
    } catch (error) {
      // Older Anchor clients can lose the logs when wrapping a failed receipt.
      const signature = tx instanceof VersionedTransaction ? tx.signatures[0] : tx.signature;
      if (signature?.some((byte) => byte !== 0)) {
        const receipt = await connection.getTransaction(anchor.utils.bytes.bs58.encode(signature), {
          commitment: "confirmed",
          maxSupportedTransactionVersion: 0,
        });
        if (receipt?.meta?.err) throw new Error(receipt.meta.logMessages?.join("\n") ?? String(error));
      }
      throw error;
    }
  }
  async function confirmedReceipt(signature: string) {
    for (let attempt = 0; attempt < 100; attempt++) {
      const receipt = await connection.getTransaction(signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });
      if (receipt) return receipt;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Confirmed receipt unavailable: ${signature}`);
  }
  const send = (...instructions: TransactionInstruction[]) => sendTransaction(new Transaction().add(...instructions));
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
    meta(tokenProgram),
    meta(vault, true),
    meta(spokeVault, true),
    meta(sourceDelegate),
  ];
  const fillMetas = (inPlace: boolean): Meta[] => [
    ...baseMetas(),
    meta(mint),
    meta(tokenProgram),
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
    readonly(tokenProgram),
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
      lookupTable?: AddressLookupTableAccount;
      before?: TransactionInstruction[];
      after?: TransactionInstruction[];
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
      const instructions = [
        ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }),
        ...(opts.before ?? []),
        instruction,
        ...(opts.after ?? []),
      ];
      const recentBlockhash = (await connection.getLatestBlockhash()).blockhash;
      const tx = opts.lookupTable
        ? new VersionedTransaction(
            new TransactionMessage({ payerKey: owner, recentBlockhash, instructions }).compileToV0Message([
              opts.lookupTable,
            ])
          )
        : new Transaction({ feePayer: owner, recentBlockhash }).add(...instructions);
      if (opts.failed) {
        if (tx instanceof VersionedTransaction) tx.sign([wallet]);
        else tx.sign(wallet);
        const signature = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: true });
        await connection.confirmTransaction(signature, "confirmed");
        const receipt = await confirmedReceipt(signature);
        assert.isNotNull(receipt!.meta!.err, "must be a failed transaction, never an accepted fill event");
        return {
          signature,
          failedReceipt: {
            logs: receipt!.meta!.logMessages ?? [],
            attemptedEvents: processEventFromTx(receipt!, [spoke]),
          },
        };
      }
      const signature = await sendTransaction(tx);
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
            meta(tokenProgram),
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
          readonly(tokenProgram),
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
    // Genesis gives the local wallet more lamports than JS receipt numbers can represent exactly.
    // Bound its balance before testing exact transaction-fee and rent-refund accounting.
    const genesisBalance = await connection.getBalance(owner);
    if (!Number.isSafeInteger(genesisBalance))
      await send(
        SystemProgram.transfer({
          fromPubkey: owner,
          toPubkey: Keypair.generate().publicKey,
          lamports: BigInt(genesisBalance) - 1_000_000_000_000n,
        })
      );
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
    tokenProgram = TOKEN_PROGRAM_ID;
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

  // Execute the retained generated instruction builder, including its account metas.
  const createAccounts = (owners: PublicKey[]) => {
    const generated = SvmSpokeClient.getCreateTokenAccountsInstruction({
      signer: createNoopSigner(address(owner.toBase58())),
      mint: address(mint.toBase58()),
      tokenProgram: address(tokenProgram.toBase58()),
    });
    return new TransactionInstruction({
      programId: new PublicKey(generated.programAddress),
      data: Buffer.from(generated.data as Uint8Array),
      keys: [
        ...generated.accounts.map((a) => ({
          pubkey: new PublicKey(a.address),
          isSigner: a.role >= 2,
          isWritable: a.role % 2 === 1,
        })),
        ...owners.flatMap((who) => [
          readonly(who),
          writable(getAssociatedTokenAddressSync(mint, who, true, tokenProgram)),
        ]),
      ],
    });
  };
  async function alternateMint(native = false) {
    tokenProgram = native ? TOKEN_PROGRAM_ID : TOKEN_2022_PROGRAM_ID;
    mint = native
      ? NATIVE_MINT
      : await createMint(connection, wallet, owner, null, 6, undefined, undefined, tokenProgram);
    const ata = async (who: PublicKey) =>
      (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, who, true, undefined, undefined, tokenProgram))
        .address;
    [vault, spokeVault, userAta, recipientAta, depositAta] = await Promise.all([
      ata(vaultAuthority),
      ata(state),
      ata(owner),
      ata(recipient),
      ata(depositor.publicKey),
    ]);
    if (!native) await mintTo(connection, wallet, mint, userAta, wallet, amount * 10n, [], undefined, tokenProgram);
  }
  const sourcePath = (failAfter = false) =>
    path([
      approve(mint, sourceDelegate),
      {
        op: OP.ADAPTER_CALL,
        input: call(
          spoke.programId,
          sourceMetas(),
          depositInput({
            depositor: owner,
            recipient,
            inputToken: mint,
            outputToken: mint,
            inputAmount: amount,
            outputAmount: amount,
            destinationChainId: BigInt(chainId.toString()),
            nonce: 7n,
            quoteTimestamp: now,
            fillDeadline: now + 600,
            dstStepId: Buffer.alloc(32, 0x71),
          })
        ),
      },
      ...(failAfter ? [floor(mint, 1n)] : []),
    ]);
  const witness = (dst: Path, who = recipient, id = 1): RelayData => ({
    depositor: owner,
    recipient: who,
    exclusiveRelayer: PublicKey.default,
    inputToken: mint,
    outputToken: mint,
    inputAmount: [...word(amount)],
    outputAmount: new BN(amount.toString()),
    originChainId: chainId,
    depositId: [...Buffer.alloc(32, id)],
    fillDeadline: now + 600,
    exclusivityDeadline: 0,
    message: Buffer.concat([PREFIX, pathId(dst)]),
  });
  async function lookup(instructions: TransactionInstruction[], accounts: AccountMeta[]) {
    const [create, key] = AddressLookupTableProgram.createLookupTable({
      authority: owner,
      payer: owner,
      recentSlot: (await connection.getSlot("confirmed")) - 1,
    });
    await send(create);
    const addresses = [
      ...new Map(
        [...accounts, ...instructions.flatMap((i) => [readonly(i.programId), ...i.keys])].map((a) => [
          a.pubkey.toBase58(),
          a.pubkey,
        ])
      ).values(),
    ];
    for (let offset = 0; offset < addresses.length; offset += 20)
      await send(
        AddressLookupTableProgram.extendLookupTable({
          lookupTable: key,
          authority: owner,
          payer: owner,
          addresses: addresses.slice(offset, offset + 20),
        })
      );
    const table = (await connection.getAddressLookupTable(key)).value!;
    while ((await connection.getSlot("finalized")) <= table.state.lastExtendedSlot)
      await new Promise((resolve) => setTimeout(resolve, 200));
    return (await connection.getAddressLookupTable(key, { commitment: "finalized" })).value!;
  }

  for (const direction of ["deposit", "fill"] as const) {
    it(`CPI-guarded StepDelegate funding: ${direction}, rejected approvals and downstream rollback`, async () => {
      await alternateMint();
      // Gateway funding accepts a non-ATA source owned by the relayer/depositor.
      userAta = await createAccount(connection, wallet, mint, owner, Keypair.generate(), undefined, tokenProgram);
      await mintTo(connection, wallet, mint, userAta, wallet, amount * 2n, [], undefined, tokenProgram);
      await send(
        createReallocateInstruction(userAta, owner, [ExtensionType.CpiGuard], owner, [], tokenProgram),
        createEnableCpiGuardInstruction(userAta, owner, [], tokenProgram)
      );
      assert.isTrue(getCpiGuard(await getAccount(connection, userAta, undefined, tokenProgram))!.lockCpi);
      assert.isNull(
        getCpiGuard(await getAccount(connection, vault, undefined, tokenProgram)),
        "guard belongs to the user account, not the Gateway vault"
      );
      const good = direction === "deposit" ? sourcePath() : destination(false);
      const bad =
        direction === "deposit"
          ? sourcePath(true)
          : path([approve(mint, fillDelegate), fillCommand(false), floor(mint, 1n)]);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const run = async (p: Path, allowance?: bigint, ownerFunding = false) => {
        const delegate = pda(GATEWAY, Buffer.from("step_funding"), pathId(p), mint.toBuffer(), u64(deadline));
        if (allowance !== undefined)
          await approveChecked(
            connection,
            wallet,
            mint,
            userAta,
            delegate,
            wallet,
            allowance,
            6,
            [],
            undefined,
            tokenProgram
          );
        const relays = direction === "fill" ? [witness(p)] : [];
        return execute(p, {
          relays,
          funds: [funding(userAta, mint, amount, ownerFunding ? undefined : deadline)],
          extra: [readonly(delegate)],
        });
      };
      const fundingBefore = (await getAccount(connection, userAta, undefined, tokenProgram)).amount;
      const payerBefore = await connection.getBalance(fillPayer);
      const unchanged = async (p: Path, allowance: bigint) => {
        const fundingAccount = await getAccount(connection, userAta, undefined, tokenProgram);
        assert.equal(fundingAccount.amount, fundingBefore);
        assert.equal(fundingAccount.delegatedAmount, allowance);
        assert.isTrue(fundingAccount.owner.equals(owner));
        assert.isTrue(getCpiGuard(fundingAccount)!.lockCpi);
        assert.equal(
          fundingAccount.delegate?.toBase58() ?? null,
          allowance === 0n
            ? null
            : pda(GATEWAY, Buffer.from("step_funding"), pathId(p), mint.toBuffer(), u64(deadline)).toBase58()
        );
        assert.equal((await getAccount(connection, vault, undefined, tokenProgram)).amount, 0n);
        assert.isNull((await getAccount(connection, vault, undefined, tokenProgram)).delegate);
        assert.equal((await getAccount(connection, spokeVault, undefined, tokenProgram)).amount, 0n);
        assert.equal((await getAccount(connection, recipientAta, undefined, tokenProgram)).amount, 0n);
        assert.equal(await connection.getBalance(fillPayer), payerBefore);
        assert.isNull(await connection.getAccountInfo(status(witness(p))));
      };
      await expectFailure(run(good), "InvalidStepFundingApproval");
      await unchanged(good, 0n);
      await expectFailure(run(good, amount - 1n), "InvalidStepFundingApproval");
      await unchanged(good, amount - 1n);
      // A co-signing owner still cannot transfer a guarded account through CPI.
      await expectFailure(run(good, undefined, true), "CPI Guard");
      await unchanged(good, amount - 1n);
      await expectFailure(run(bad, amount), "BalanceRequirement");
      await unchanged(bad, amount);
      const { signature } = await run(good, amount);
      const fundingAccount = await getAccount(connection, userAta, undefined, tokenProgram);
      assert.equal(fundingAccount.amount, fundingBefore - amount);
      assert.equal(fundingAccount.delegatedAmount, 0n);
      assert.isNull(fundingAccount.delegate);
      assert.isTrue(getCpiGuard(fundingAccount)!.lockCpi);
      assert.equal((await getAccount(connection, vault, undefined, tokenProgram)).amount, 0n);
      assert.isNull((await getAccount(connection, vault, undefined, tokenProgram)).delegate);
      assert.equal(
        (await getAccount(connection, direction === "deposit" ? spokeVault : recipientAta, undefined, tokenProgram))
          .amount,
        amount
      );
      const events = await readEventsUntilFound(connection, signature, [spoke]);
      const record = events.find((e) => e.name === (direction === "deposit" ? "fundsDeposited" : "filledRelay"))!.data;
      assert.equal((direction === "deposit" ? record.inputAmount : record.outputAmount).toString(), amount.toString());
      if (direction === "fill") {
        await filled(witness(good));
        assert.equal(
          payerBefore - (await connection.getBalance(fillPayer)),
          (await connection.getAccountInfo(status(witness(good))))!.lamports
        );
      } else assert.equal(await connection.getBalance(fillPayer), payerBefore);
    });
  }

  for (const existing of [false, true]) {
    it(`native SOL source deposit with ${existing ? "existing" : "new"} wrapped account`, async () => {
      await alternateMint(true);
      // Close the empty fixture account so the new-account case provisions it in the deposit transaction.
      if (!existing) await send(createCloseAccountInstruction(userAta, owner, owner));
      const vaultBefore = await connection.getBalance(spokeVault);
      const gatewayBefore = await connection.getBalance(vault);
      const wrapping = [
        ...(!existing ? [createAccounts([owner])] : []),
        SystemProgram.transfer({ fromPubkey: owner, toPubkey: userAta, lamports: amount }),
        createSyncNativeInstruction(userAta),
      ];
      const src = sourcePath();
      const table = await lookup(wrapping, remaining());
      // LUT setup fees are outside the wrapped-SOL transaction accounting.
      const { signature } = await execute(src, {
        funds: [funding(userAta, mint, amount)],
        before: wrapping,
        after: [createCloseAccountInstruction(userAta, owner, owner)],
        lookupTable: table,
      });
      assert.isNull(await connection.getAccountInfo(userAta));
      assert.equal((await getAccount(connection, spokeVault)).amount, amount);
      assert.equal((await connection.getBalance(spokeVault)) - vaultBefore, Number(amount));
      assert.equal(await connection.getBalance(vault), gatewayBefore);
      const event = (await readEventsUntilFound(connection, signature, [spoke])).find(
        (e) => e.name === "fundsDeposited"
      )!.data;
      assert.equal(event.inputAmount.toString(), amount.toString());
      assert.equal(event.inputToken.toBase58(), NATIVE_MINT.toBase58());
      const receipt = await confirmedReceipt(signature);
      // Parameter-buffer setup/cleanup has its own fees; use the execution receipt for an exact payer delta.
      const ownerIndex = receipt.transaction.message.staticAccountKeys.findIndex((key) => key.equals(owner));
      assert.isTrue(Number.isSafeInteger(receipt.meta!.preBalances[ownerIndex]));
      const refunded = receipt.meta!.preBalances.reduce(
        (sum, lamports, i) => sum + (i !== ownerIndex && receipt.meta!.postBalances[i] === 0 ? lamports : 0),
        0
      );
      assert.equal(
        receipt.meta!.preBalances[ownerIndex] - receipt.meta!.postBalances[ownerIndex],
        Number(amount) + receipt.meta!.fee - refunded
      );
    });
  }

  it("provisions a missing Spoke vault before a V5 deposit using the generated account builder", async () => {
    // A fresh state has no vault for this mint. Funding still comes from the existing user account.
    ({ state } = await initializeState());
    now = (await spoke.account.state.fetch(state)).currentTime;
    spokeVault = getAssociatedTokenAddressSync(mint, state, true);
    const src = sourcePath();
    const funds = [funding(userAta, mint, amount)];
    const before = (await getAccount(connection, userAta)).amount;
    await expectFailure(execute(src, { funds }), "InvalidTokenAccount");
    assert.isNull(await connection.getAccountInfo(spokeVault));
    assert.equal((await getAccount(connection, userAta)).amount, before);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    assert.isNull((await getAccount(connection, vault)).delegate);
    const create = createAccounts([state]);
    const { signature } = await execute(src, {
      funds,
      before: [create],
      lookupTable: await lookup([create], remaining()),
    });
    assert.equal((await getAccount(connection, userAta)).amount, before - amount);
    assert.equal((await getAccount(connection, spokeVault)).amount, amount);
    assert.equal((await getAccount(connection, vault)).amount, 0n);
    const record = (await readEventsUntilFound(connection, signature, [spoke])).find(
      (e) => e.name === "fundsDeposited"
    )!.data;
    assert.equal(record.inputAmount.toString(), amount.toString());
  });

  for (const count of [1, 2]) {
    it(`${count} external V5 fill(s) create recipient ATAs atomically; a failing last fill rolls everything back`, async () => {
      const recipients = Array.from(
        { length: count },
        (_, i) => Keypair.fromSeed(Buffer.alloc(32, 0x41 + i)).publicKey
      );
      const atas = recipients.map((who) => getAssociatedTokenAddressSync(mint, who));
      const commands = recipients.map(
        (who, i): Command => ({
          op: OP.ADAPTER_CALL | OP.JIT,
          input: call(
            spoke.programId,
            [
              ...baseMetas(),
              meta(mint),
              meta(tokenProgram),
              meta(vault, true),
              meta(atas[i], true),
              meta(fillDelegate),
              injected(),
              injected(),
              meta(SystemProgram.programId),
            ],
            fillInput(who, mint, amount)
          ),
        })
      );
      const dst = path([approve(mint, fillDelegate), ...commands]);
      const relays = recipients.map((who, i) => witness(dst, who, i + 1));
      const funds = [funding(userAta, mint, amount * BigInt(count))];
      const extra = atas.map(writable);
      const create = createAccounts(recipients);
      const table = await lookup([create], [...remaining(relays), ...extra]);
      const balanceBefore = (await getAccount(connection, userAta)).amount;
      const payerBefore = await connection.getBalance(fillPayer);
      const unchanged = async () => {
        assert.equal((await getAccount(connection, userAta)).amount, balanceBefore);
        const source = await getAccount(connection, vault);
        assert.equal(source.amount, 0n);
        assert.isNull(source.delegate);
        assert.equal(await connection.getBalance(fillPayer), payerBefore);
        for (let i = 0; i < count; i++) {
          assert.isNull(await connection.getAccountInfo(atas[i]));
          assert.isNull(await connection.getAccountInfo(status(relays[i])));
        }
      };
      await expectFailure(execute(dst, { relays, funds, extra, lookupTable: table }), "InvalidTokenAccount");
      await unchanged();
      const badRelays = relays.map((r, i) =>
        i === count - 1 ? { ...r, outputAmount: new BN((amount - 1n).toString()) } : r
      );
      const failure = await execute(dst, {
        relays: badRelays,
        funds,
        extra,
        before: [create],
        lookupTable: table,
        failed: true,
      });
      assert.include(failure.failedReceipt!.logs.join("\n"), "FillOutputAmountTooLow");
      assert.equal(failure.failedReceipt!.attemptedEvents.filter((e) => e.name === "filledRelay").length, count - 1);
      await unchanged();
      assert.isNull(await connection.getAccountInfo(status(badRelays[count - 1])));
      const { signature } = await execute(dst, { relays, funds, extra, before: [create], lookupTable: table });
      assert.equal((await getAccount(connection, userAta)).amount, balanceBefore - amount * BigInt(count));
      assert.equal((await getAccount(connection, vault)).amount, 0n);
      assert.isNull((await getAccount(connection, vault)).delegate);
      let rent = 0;
      for (let i = 0; i < count; i++) {
        const account = await getAccount(connection, atas[i]);
        assert.equal(account.amount, amount);
        assert.isTrue(account.owner.equals(recipients[i]));
        await filled(relays[i]);
        rent += (await connection.getAccountInfo(status(relays[i])))!.lamports;
      }
      assert.equal(payerBefore - (await connection.getBalance(fillPayer)), rent);
      const events = (await readEventsUntilFound(connection, signature, [spoke])).filter(
        (e) => e.name === "filledRelay"
      );
      assert.equal(events.length, count);
      for (let i = 0; i < count; i++) assert.deepEqual(events[i].data.depositId, relays[i].depositId);
      const receipt = await confirmedReceipt(signature);
      const bytes = new VersionedTransaction(receipt.transaction.message).serialize().length;
      assert.isAtMost(bytes, 1232, "serialized v0 transaction including its signature slots");
      console.info(`      ${count} external fill(s): ${bytes} bytes, ${receipt.meta!.computeUnitsConsumed} CU`);
      assert.isAtMost(
        receipt.meta!.computeUnitsConsumed!,
        1_400_000,
        "budget for this concrete buffered v0 transaction"
      );
    });
  }

  for (const failure of [undefined, "swap", "floor"] as const) {
    it(`Across fill then real Raydium CPMM swap: ${failure ?? "delivery and replay"}`, async () => {
      const executorAuthority = pda(GATEWAY, Buffer.from("executor_authority"));
      const fixture = await createSwapFixture(
        provider,
        wallet,
        mint,
        vault,
        vaultAuthority,
        executorAuthority,
        recipient
      );
      const minimum = (amount * 9n) / 10n;
      const impossible = 2_000_000_000n;
      const dst = path([
        fillCommand(),
        approve(mint, executorAuthority),
        fixture.swap(failure === "swap" ? impossible : 0n),
        floor(fixture.outputMint, failure === "floor" ? impossible : minimum),
        transfer(fixture.outputMint, recipient),
      ]);
      const relay = await origin(pathId(dst));
      const lookupTable = await lookup([], [...remaining([relay]), ...fixture.extra]);
      const watched = [
        vault,
        fixture.outputVault,
        fixture.recipientAta,
        fixture.poolInput,
        fixture.poolOutput,
        fixture.pool,
        fixture.observation,
        fillPayer,
        status(relay),
        userAta,
      ];
      const before = await connection.getMultipleAccountsInfo(watched);
      const opts = {
        relays: [relay],
        extra: fixture.extra,
        lookupTable,
        funds: [funding(userAta, mint, amount, undefined)],
      };
      if (failure) {
        const { failedReceipt } = await execute(dst, { ...opts, failed: true });
        assert.include(
          failedReceipt!.logs.join("\n"),
          failure === "swap" ? "ExceededSlippage" : "BalanceRequirementNotMet"
        );
        assert.isTrue(failedReceipt!.logs.some((log) => log.startsWith(`Program ${SWAP_PROGRAM} invoke`)));
        assert.equal(failedReceipt!.attemptedEvents.filter((e) => e.name === "filledRelay").length, 1);
        assert.deepEqual(
          await connection.getMultipleAccountsInfo(watched),
          before,
          "funding, pool swap, fill and payer changes roll back"
        );
      } else {
        const { signature } = await execute(dst, opts);
        await filled(relay);
        const delivered = (await getAccount(connection, fixture.recipientAta)).amount;
        assert.isTrue(delivered >= minimum);
        assert.equal((await getAccount(connection, fixture.poolInput)).amount, 1_000_000_000n + amount);
        assert.equal((await getAccount(connection, fixture.poolOutput)).amount, 1_000_000_000n - delivered);
        assert.equal((await getAccount(connection, fixture.outputVault)).amount, 0n);
        const inputAccount = await getAccount(connection, vault);
        assert.equal(inputAccount.amount, 0n);
        assert.isTrue(inputAccount.owner.equals(vaultAuthority));
        assert.isNull(inputAccount.delegate, "full swap consumes the exact delegate allowance");
        const receipt = await confirmedReceipt(signature);
        assert.isTrue(receipt!.meta!.logMessages!.some((log) => log.startsWith(`Program ${SWAP_PROGRAM} invoke`)));
        assert.equal(processEventFromTx(receipt!, [spoke]).filter((e) => e.name === "filledRelay").length, 1);
        const settled = await connection.getMultipleAccountsInfo(watched);
        await expectFailure(execute(dst, opts), "RelayFilled");
        assert.deepEqual(await connection.getMultipleAccountsInfo(watched), settled);
      }
    });
  }

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
