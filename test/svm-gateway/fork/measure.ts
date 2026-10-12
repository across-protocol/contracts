import { strict as assert } from "assert";
import { AnchorProvider, BN, Idl, Program, Wallet } from "@anchor-lang/core";
import { AddressLookupTableProgram, PublicKey, SystemProgram, SYSVAR_CLOCK_PUBKEY, AccountMeta } from "@solana/web3.js";
import {
  NATIVE_MINT,
  TOKEN_PROGRAM_ID,
  getAccount,
  getAssociatedTokenAddressSync,
  createApproveCheckedInstruction,
} from "@solana/spl-token";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  GATEWAY,
  SPOKE,
  STATE,
  VAULT_AUTHORITY,
  EXECUTOR,
  USDC,
  POOL,
  CPMM,
  payer,
  recipient,
  CASES,
  Flow,
  poolKeys,
} from "./config";
import { Recorder } from "./recorder";
import { sha256 } from "../../../scripts/svm/forkSnapshot";
import { Command, Path, OP, PREFIX, approve, call, meta, injected, pda } from "../wire";
import {
  tape,
  u16,
  u32,
  u64,
  word,
  vec,
  jitQueue,
  hash,
  funding,
  floor,
  transfer,
  pathId,
  executeParams,
} from "../wire";
import { seed, BUFFER_FRAGMENT_BYTES } from "../cu/config";
import swapIdl from "../fixtures/raydium_cp_swap.244e1241.json";

export async function measure(
  url: string,
  output: string,
  sample: number,
  spokeIdl: string,
  gatewayIdl: string,
  marginBps: number,
  flows: readonly Flow[] = CASES
) {
  const wallet = payer(sample),
    owner = wallet.publicKey,
    recipientKey = recipient(sample).publicKey;
  const recorder = new Recorder(url, wallet, path.join(output, `receipts-${sample}.jsonl`), marginBps);
  await recorder.verifyLocal();
  const connection = recorder.connection,
    provider = new AnchorProvider(connection, new Wallet(wallet), { commitment: "confirmed" });
  const spoke = new Program(JSON.parse(readFileSync(spokeIdl, "utf8")) as Idl, provider);
  const gateway = new Program(JSON.parse(readFileSync(gatewayIdl, "utf8")) as Idl, provider);
  const swapProgram = new Program(swapIdl as Idl, provider);
  assert(spoke.programId.equals(SPOKE) && gateway.programId.equals(GATEWAY));
  const stateAccount = await connection.getAccountInfo(STATE);
  assert(stateAccount);
  const state = spoke.coder.accounts.decode("state", stateAccount.data) as {
    pausedDeposits: boolean;
    pausedFills: boolean;
    seed: BN;
    chainId: BN;
  };
  assert(!state.pausedDeposits && !state.pausedFills && state.seed.eqn(0));
  const chainId = BigInt(state.chainId.toString());
  const poolAccount = await connection.getAccountInfo(POOL);
  assert(poolAccount && poolAccount.owner.equals(CPMM));
  const keys = poolKeys(poolAccount.data);
  const eventAuthority = pda(SPOKE, Buffer.from("__event_authority"));
  const fillPayer = pda(SPOKE, Buffer.from("v5_fill_payer"), owner.toBuffer());
  const fillDelegate = pda(SPOKE, Buffer.from("v5_fill_delegate"));
  const depositDelegate = pda(SPOKE, Buffer.from("v5_deposit_delegate"));
  const dispatch = pda(GATEWAY, Buffer.from("dispatch_authority"), SPOKE.toBuffer());
  const ata = (mint: PublicKey, authority: PublicKey) => getAssociatedTokenAddressSync(mint, authority, true);
  const account = (pubkey: PublicKey, isWritable = false): AccountMeta => ({ pubkey, isWritable, isSigner: false });
  const baseMetas = (mint: PublicKey) => [
    meta(STATE),
    meta(eventAuthority),
    meta(SPOKE),
    meta(mint),
    meta(TOKEN_PROGRAM_ID),
    meta(ata(mint, VAULT_AUTHORITY), true),
  ];
  const rows = [];
  for (const flow of flows) {
    const swapDeposit = flow === "swap-deposit",
      fill = flow.startsWith("fill"),
      swapFill = flow === "fill-swap" || flow === "fill-jit-swap";
    const inputMint = swapDeposit ? NATIVE_MINT : USDC,
      outputMint = swapFill ? NATIVE_MINT : USDC;
    // Small amounts relative to the sampled pool's liquidity. Native-account creation is a separate workload.
    const amount = swapDeposit ? 1_000_000n : 100_000n;
    const source = ata(inputMint, owner),
      vault = ata(inputMint, VAULT_AUTHORITY),
      outputVault = ata(outputMint, VAULT_AUTHORITY),
      spokeVault = ata(USDC, STATE),
      recipientAta = ata(outputMint, recipientKey);
    const now = Number((await connection.getAccountInfo(SYSVAR_CLOCK_PUBKEY))!.data.readBigInt64LE(32));
    const sourceBefore = (await getAccount(connection, source)).amount,
      recipientBefore = (await getAccount(connection, recipientAta)).amount,
      spokeBefore = (await getAccount(connection, spokeVault)).amount;
    const rentBefore = await connection.getBalance(fillPayer);
    const poolBefore = await Promise.all(
      [keys.vault0, keys.vault1].map((k) => getAccount(connection, k).then((a) => a.amount))
    );
    const swapIx = async (input: PublicKey, output: PublicKey) =>
      swapProgram.methods
        .swapBaseInput(new BN(0), new BN(1))
        .accountsStrict({
          payer: EXECUTOR,
          authority: pda(CPMM, Buffer.from("vault_and_lp_mint_auth_seed")),
          ammConfig: keys.config,
          poolState: POOL,
          inputTokenAccount: ata(input, VAULT_AUTHORITY),
          outputTokenAccount: ata(output, VAULT_AUTHORITY),
          inputVault: input.equals(keys.mint0) ? keys.vault0 : keys.vault1,
          outputVault: output.equals(keys.mint0) ? keys.vault0 : keys.vault1,
          inputTokenProgram: TOKEN_PROGRAM_ID,
          outputTokenProgram: TOKEN_PROGRAM_ID,
          inputTokenMint: input,
          outputTokenMint: output,
          observationState: keys.observation,
        })
        .instruction();
    const swapInstruction = swapDeposit || swapFill ? await swapIx(inputMint, outputMint) : undefined;
    const swapCommands: Command[] = swapInstruction
      ? [
          approve(inputMint, EXECUTOR),
          {
            op: OP.CALL,
            input: call(
              CPMM,
              swapInstruction.keys.map((k) => ({
                pubkey: k.pubkey,
                flags: Number(k.isWritable) | (Number(k.isSigner) << 1),
              })),
              swapInstruction.data,
              [Buffer.concat([inputMint.toBuffer(), u16(10000), u32(8)])]
            ),
          },
        ]
      : [];
    let commands: Command[],
      jit: Buffer[] = [];
    let status: PublicKey | undefined;
    if (!fill) {
      const input = spoke.coder.types.encode("v5AdapterInput", {
        depositV1: [
          {
            depositParams: {
              depositor: owner,
              recipient: recipientKey,
              inputToken: USDC,
              outputToken: USDC,
              inputAmount: new BN((swapDeposit ? 1n : amount).toString()),
              outputAmount: [...word(swapDeposit ? 1n : amount)],
              destinationChainId: new BN(1),
              exclusiveRelayer: PublicKey.default,
              depositNonce: new BN(sample * 100 + CASES.indexOf(flow)),
              quoteTimestamp: now,
              fillDeadline: now + 600,
              exclusivityParameter: 0,
            },
            dstStepId: [...seed(`fork:${sample}:${flow}:destination`)],
            inputAmountMode: { inputVaultBalance: { bips: 10000 } },
            modificationRules: { authority: Array(20).fill(0), allowOutputAmount: false, allowExclusiveRelayer: false },
          },
        ],
      });
      commands = [
        ...swapCommands,
        approve(USDC, depositDelegate),
        {
          op: OP.ADAPTER_CALL,
          input: call(SPOKE, [...baseMetas(USDC), meta(spokeVault, true), meta(depositDelegate)], input),
        },
      ];
    } else {
      const external = flow === "fill-external",
        who = external ? recipientKey : VAULT_AUTHORITY;
      const input = spoke.coder.types.encode("v5AdapterInput", {
        fillV1: [{ recipient: who, outputToken: USDC, minOutputAmount: new BN(amount.toString()) }],
      });
      const adapter = {
        op: OP.ADAPTER_CALL | OP.JIT,
        input: call(
          SPOKE,
          [
            ...baseMetas(USDC),
            ...(external ? [meta(recipientAta, true)] : []),
            meta(fillDelegate),
            injected(),
            injected(),
            meta(SystemProgram.programId),
          ],
          input
        ),
      };
      commands = [approve(USDC, fillDelegate), adapter];
      if (!external)
        commands.push(
          approve(USDC, fillDelegate, 0n),
          ...(flow === "fill-jit-swap" ? [{ op: OP.PLAN_FROM_JIT | OP.JIT, input: Buffer.alloc(0) }] : swapCommands),
          floor(outputMint, swapFill ? 1n : amount),
          transfer(outputMint, recipientKey)
        );
      if (flow === "fill-jit-swap") jit.push(Buffer.concat([vec(tape(swapCommands)), vec(jitQueue([]))]));
    }
    const selected: Path = { chainId, salt: seed(`fork:${sample}:${flow}`), message: tape(commands) };
    if (fill) {
      const who = flow === "fill-external" ? recipientKey : VAULT_AUTHORITY;
      const relay = {
        depositor: owner,
        recipient: who,
        exclusiveRelayer: PublicKey.default,
        inputToken: USDC,
        outputToken: USDC,
        inputAmount: [...word(amount)],
        outputAmount: new BN(amount.toString()),
        originChainId: new BN(1),
        depositId: [...seed(`fork:${sample}:${flow}:deposit`)],
        fillDeadline: now + 600,
        exclusivityDeadline: 0,
        message: Buffer.concat([PREFIX, pathId(selected)]),
      };
      const bytes = spoke.coder.types.encode("relayData", relay);
      const digest = hash(
        Buffer.concat([bytes.subarray(0, bytes.length - 4 - relay.message.length), hash(relay.message), u64(chainId)])
      );
      status = pda(SPOKE, Buffer.from("fills"), digest);
      const value = spoke.coder.types.encode("v5FillJit", {
        relayData: relay,
        repaymentChainId: new BN(1),
        repaymentAddress: owner,
      });
      jit.unshift(Buffer.concat([status.toBuffer(), fillPayer.toBuffer(), value]));
    }
    const deadline = flow === "deposit-step-delegate" ? BigInt(now + 600) : undefined;
    const funder = deadline
      ? pda(GATEWAY, Buffer.from("step_funding"), pathId(selected), inputMint.toBuffer(), u64(deadline))
      : undefined;
    if (funder)
      await recorder.send(flow, "approval", [
        createApproveCheckedInstruction(source, inputMint, funder, owner, amount, 6),
      ]);
    const params = executeParams(selected, pathId(selected), [], jit, [funding(source, inputMint, amount, deadline)]);
    const disc = gateway.idl.accounts!.find((x) => x.name === "executeParamsAccount")!.discriminator;
    const digest = Buffer.from(sha256(Buffer.concat([Buffer.from(disc), params])), "hex");
    const buffer = pda(GATEWAY, Buffer.from("execute_params"), owner.toBuffer(), digest);
    await recorder.send(flow, "buffer-init", [
      await gateway.methods
        .initializeExecuteParams([...digest], params.length)
        .accountsStrict({ submitter: owner, executeParams: buffer, systemProgram: SystemProgram.programId })
        .instruction(),
    ]);
    for (let offset = 0; offset < params.length; offset += BUFFER_FRAGMENT_BYTES)
      await recorder.send(flow, "buffer-write", [
        await gateway.methods
          .writeExecuteParamsFragment([...digest], offset, params.subarray(offset, offset + BUFFER_FRAGMENT_BYTES))
          .accountsStrict({ submitter: owner, executeParams: buffer })
          .instruction(),
      ]);
    // Include only accounts actually referenced by this tape/funding; avoid broad fixture writability.
    const remaining = [
      account(SPOKE),
      account(dispatch),
      account(STATE),
      account(eventAuthority),
      account(TOKEN_PROGRAM_ID),
      account(inputMint),
      account(outputMint),
      account(vault, true),
      account(source, true),
      account(VAULT_AUTHORITY),
      account(SystemProgram.programId),
      ...(fill
        ? [account(fillDelegate), account(fillPayer, true), account(status!, true), account(recipientAta, true)]
        : [account(depositDelegate), account(spokeVault, true)]),
      ...(funder ? [account(funder)] : []),
      ...(swapInstruction ? [account(CPMM), ...swapInstruction.keys.map((k) => ({ ...k, isSigner: false }))] : []),
    ];
    const merged = new Map<string, AccountMeta>();
    for (const a of remaining) {
      const old = merged.get(a.pubkey.toBase58());
      merged.set(a.pubkey.toBase58(), { ...a, isWritable: a.isWritable || !!old?.isWritable });
    }
    const instruction = await gateway.methods
      .execute(null)
      .accountsStrict({
        localFundingSigner: owner,
        submitter: owner,
        executeParams: buffer,
        config: pda(GATEWAY, Buffer.from("config")),
        eventAuthority: pda(GATEWAY, Buffer.from("__event_authority")),
        program: GATEWAY,
      })
      .remainingAccounts([...merged.values()])
      .instruction();
    const slot = await connection.getSlot("finalized");
    const [create, tableAddress] = AddressLookupTableProgram.createLookupTable({
      authority: owner,
      payer: owner,
      recentSlot: slot,
    });
    await recorder.send(flow, "setup-alt", [create]);
    const addresses = [
      ...new Map(instruction.keys.filter((k) => !k.isSigner).map((k) => [k.pubkey.toBase58(), k.pubkey])).values(),
    ];
    for (let i = 0; i < addresses.length; i += 20)
      await recorder.send(flow, "setup-alt", [
        AddressLookupTableProgram.extendLookupTable({
          lookupTable: tableAddress,
          authority: owner,
          payer: owner,
          addresses: addresses.slice(i, i + 20),
        }),
      ]);
    const table = (await connection.getAddressLookupTable(tableAddress)).value!;
    assert(table);
    while ((await connection.getSlot()) <= table.state.lastExtendedSlot) await new Promise((r) => setTimeout(r, 100));
    const tx = await recorder.send(flow, "execution", [instruction], [table]);
    assert.equal(await connection.getAccountInfo(buffer), null);
    assert.equal((await getAccount(connection, source)).amount, sourceBefore - amount);
    for (const mint of [USDC, NATIVE_MINT]) {
      const a = await getAccount(connection, ata(mint, VAULT_AUTHORITY));
      assert.equal(a.amount, 0n);
      assert.equal(a.delegatedAmount, 0n);
    }
    let delivered: bigint;
    if (fill) {
      const info = (await connection.getAccountInfo(status!))!;
      const filled = spoke.coder.accounts.decode("fillStatusAccount", info.data) as any;
      assert("filled" in filled.status && filled.rentRecipient.equals(fillPayer));
      assert.equal(rentBefore - (await connection.getBalance(fillPayer)), info.lamports);
      delivered = (await getAccount(connection, recipientAta)).amount - recipientBefore;
      assert(swapFill ? delivered > 0n : delivered === amount);
    } else {
      delivered = (await getAccount(connection, spokeVault)).amount - spokeBefore;
      assert(swapDeposit ? delivered > 0n : delivered === amount);
    }
    if (swapInstruction) {
      const after = await Promise.all(
        [keys.vault0, keys.vault1].map((k) => getAccount(connection, k).then((a) => a.amount))
      );
      const i = inputMint.equals(keys.mint0) ? 0 : 1;
      assert(after[i] > poolBefore[i] && after[1 - i] < poolBefore[1 - i]);
    }
    const transactions = recorder.transactions.filter((t) => t.flow === flow && !t.phase.startsWith("setup"));
    rows.push({
      flow,
      sample,
      inputMint: inputMint.toBase58(),
      outputMint: outputMint.toBase58(),
      amount: amount.toString(),
      delivered: delivered.toString(),
      pathId: pathId(selected).toString("hex"),
      paramsBytes: params.length,
      bufferFragmentBytes: BUFFER_FRAGMENT_BYTES,
      execution: tx.consumedCu,
      totalConsumedCu: transactions.reduce((n, t) => n + t.consumedCu, 0),
      transactions,
    });
    console.log(
      `${flow}[${sample}]: execution ${tx.consumedCu} CU; limit ${tx.computeUnitLimit}; ${transactions.length} fee-bearing transactions`
    );
  }
  writeFileSync(
    path.join(output, `sample-${sample}.json`),
    JSON.stringify(
      { rows, setupTransactions: recorder.transactions.filter((t) => t.phase.startsWith("setup")) },
      null,
      2
    ) + "\n"
  );
  return rows;
}
