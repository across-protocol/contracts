import { strict as assert } from "assert";
import { AnchorProvider, BN, Idl, Program, Wallet } from "@coral-xyz/anchor";
import {
  AccountMeta,
  ComputeBudgetProgram,
  Connection,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  burn,
  createApproveCheckedInstruction,
  createMint,
  getAccount,
  getAssociatedTokenAddressSync,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import { createHash } from "crypto";
import { appendFileSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  AMOUNT,
  Case,
  CHAIN_ID,
  FUNDING_DEADLINE,
  Measurement,
  NOW,
  SAMPLES,
  SPOKE,
  WALLET,
  keypair,
  seed,
} from "./config";
import {
  GATEWAY,
  PREFIX,
  Command,
  Path,
  OP,
  approve,
  call,
  canonicalInPlace,
  executeParams,
  funding,
  hash,
  injected,
  meta,
  pathId,
  pda,
  tape,
  u64,
  word,
} from "../wire";

const mode = process.env.SVM_CU_MODE;
assert(mode === "legacy" || mode === "v5", "Run yarn bench-svm-cu");
const output = process.env.SVM_CU_OUTPUT!;
const connection = new Connection(process.env.SVM_CU_RPC!, "confirmed");
const provider = new AnchorProvider(connection, new Wallet(WALLET), { commitment: "confirmed" });
const load = (file: string) => new Program(JSON.parse(readFileSync(file, "utf8")) as Idl, provider);
const spoke = load(process.env.SVM_CU_SPOKE_IDL!);
const gateway = load(process.env.SVM_CU_GATEWAY_IDL!);
assert(spoke.programId.equals(SPOKE));
assert(gateway.programId.equals(GATEWAY));
const owner = WALLET.publicKey;
const eventAuthority = pda(SPOKE, Buffer.from("__event_authority"));
const vaultAuthority = pda(GATEWAY, Buffer.from("vault_authority"));
const fillPayer = pda(SPOKE, Buffer.from("v5_fill_payer"), owner.toBuffer());
const dispatch = pda(GATEWAY, Buffer.from("dispatch_authority"), SPOKE.toBuffer());
const depositDelegate = pda(SPOKE, Buffer.from("v5_deposit_delegate"));
const fillDelegate = pda(SPOKE, Buffer.from("v5_fill_delegate"));
const measurements: Measurement[] = [];
const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");
const account = (pubkey: PublicKey, isWritable = false): AccountMeta => ({ pubkey, isWritable, isSigner: false });
const receiptPath = path.join(output, `${mode}-receipts.jsonl`);
writeFileSync(receiptPath, "");

async function send(label: string, instructions: TransactionInstruction[]) {
  const transaction = new Transaction().add(
    ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }),
    ...instructions
  );
  const signature = await provider.sendAndConfirm(transaction);
  for (let attempt = 0; attempt < 100; attempt++) {
    const receipt = await connection.getTransaction(signature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (receipt) {
      assert.equal(receipt.meta?.err, null);
      assert.equal(typeof receipt.meta?.computeUnitsConsumed, "number");
      appendFileSync(receiptPath, JSON.stringify({ label, signature, ...receipt }) + "\n");
      return receipt.meta!.computeUnitsConsumed!;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Missing confirmed receipt: ${signature}`);
}

async function runtime() {
  const programs: Record<string, string> = {};
  const loader = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
  for (const id of [TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID]) {
    const info = await connection.getAccountInfo(id);
    assert(info?.executable);
    let code = info.data;
    if (info.owner.equals(loader)) {
      assert.equal(code.readUInt32LE(0), 2, "upgradeable Program account");
      const data = await connection.getAccountInfo(new PublicKey(code.subarray(4, 36)));
      assert(data && data.owner.equals(loader));
      code = data.data.subarray(45); // Exclude deployment slot and upgrade authority metadata.
    }
    programs[id.toBase58()] = sha256(code);
  }
  const features = await connection.getProgramAccounts(new PublicKey("Feature111111111111111111111111111111111111"));
  const active = features
    .filter(({ account }) => account.data[0] === 1)
    .map(({ pubkey }) => pubkey.toBase58())
    .sort();
  return { version: await connection.getVersion(), programs, activeFeaturesSha256: sha256(JSON.stringify(active)) };
}

async function main() {
  const runtimeInfo = await runtime();
  if (mode === "v5") {
    const loader = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
    await send("setup:gateway", [
      await gateway.methods
        .initialize(new BN(CHAIN_ID.toString()))
        .accountsStrict({
          payer: owner,
          config: pda(GATEWAY, Buffer.from("config")),
          program: GATEWAY,
          programData: pda(loader, GATEWAY.toBuffer()),
          systemProgram: SystemProgram.programId,
        })
        .instruction(),
    ]);
    await send("setup:rent-float", [
      SystemProgram.transfer({ fromPubkey: owner, toPubkey: fillPayer, lamports: 20_000_000 }),
    ]);
  }
  for (const sample of SAMPLES) {
    const stateSeed = BigInt(sample + 1);
    const [state, stateBump] = PublicKey.findProgramAddressSync([Buffer.from("state"), u64(stateSeed)], SPOKE);
    const mintKeypair = keypair(`${sample}:mint`);
    const mint = await createMint(connection, WALLET, owner, null, 6, mintKeypair);
    const recipientKeypair = keypair(`${sample}:recipient`);
    const recipient = recipientKeypair.publicKey;
    const ata = async (authority: PublicKey) =>
      (await getOrCreateAssociatedTokenAccount(connection, WALLET, mint, authority, true)).address;
    const [source, recipientAta, spokeVault] = await Promise.all([ata(owner), ata(recipient), ata(state)]);
    const vault = mode === "v5" ? await ata(vaultAuthority) : getAssociatedTokenAddressSync(mint, vaultAuthority, true);
    await send("setup:state", [
      await spoke.methods
        .initialize(new BN(stateSeed.toString()), 0, new BN(CHAIN_ID.toString()), 0, owner, 3600, 14400)
        .accountsStrict({ signer: owner, state, systemProgram: SystemProgram.programId })
        .instruction(),
    ]);
    await send("setup:clock", [
      await spoke.methods.setCurrentTime(NOW).accountsStrict({ state, signer: owner }).instruction(),
    ]);
    const fixture = { mint: mint.toBase58(), recipient: recipient.toBase58(), state: state.toBase58(), stateBump };
    const record = (
      name: Case,
      execution: number,
      approval = 0,
      buffer = 0,
      extra: Record<string, string | number> = {}
    ) => {
      const row = {
        case: name,
        sample,
        execution,
        approval,
        buffer,
        total: execution + approval + buffer,
        fixture: { ...fixture, ...extra },
      };
      measurements.push(row);
      console.log(
        `${name}[${sample}]: execution=${execution}, approval=${approval}, buffer=${buffer}, total=${row.total}`
      );
    };
    const prepare = async () => {
      assert.equal((await getAccount(connection, source)).amount, 0n);
      const received = (await getAccount(connection, recipientAta)).amount;
      if (received) await burn(connection, WALLET, recipientAta, mint, recipientKeypair, received);
      await mintTo(connection, WALLET, mint, source, WALLET, AMOUNT);
      if (mode === "v5") assert.equal((await getAccount(connection, vault)).amount, 0n);
    };
    const base = { state, mint, tokenProgram: TOKEN_PROGRAM_ID, eventAuthority, program: SPOKE };
    const relay = (who: PublicKey, message: Buffer) => ({
      depositor: owner,
      recipient: who,
      exclusiveRelayer: PublicKey.default,
      inputToken: mint,
      outputToken: mint,
      inputAmount: [...word(AMOUNT)],
      outputAmount: new BN(AMOUNT.toString()),
      originChainId: new BN(1),
      depositId: [...seed(`${sample}:deposit-id`)],
      fillDeadline: NOW + 600,
      exclusivityDeadline: 0,
      message,
    });
    const relayHash = (value: ReturnType<typeof relay>) => {
      const bytes = spoke.coder.types.encode("relayData", value);
      return hash(
        Buffer.concat([
          bytes.subarray(0, bytes.length - 4 - value.message.length),
          value.message.length ? hash(value.message) : Buffer.alloc(32),
          u64(CHAIN_ID),
        ])
      );
    };
    if (mode === "legacy") {
      await prepare();
      const deposit = await spoke.methods
        .deposit(
          owner,
          recipient,
          mint,
          mint,
          new BN(AMOUNT.toString()),
          [...word(AMOUNT)],
          new BN(1),
          PublicKey.default,
          NOW,
          NOW + 600,
          0,
          Buffer.alloc(0)
        )
        .accountsStrict({
          ...base,
          signer: owner,
          delegate: PublicKey.default,
          depositorTokenAccount: source,
          vault: spokeVault,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .instruction();
      // The pinned legacy contract hashes precisely the serialized deposit arguments, without the discriminator.
      const [delegate, delegateBump] = PublicKey.findProgramAddressSync(
        [Buffer.from("delegate"), hash(deposit.data.subarray(8))],
        SPOKE
      );
      deposit.keys[2].pubkey = delegate;
      const approval = await send("legacy-deposit:approval", [
        createApproveCheckedInstruction(source, mint, delegate, owner, AMOUNT, 6),
      ]);
      const execution = await send("legacy-deposit:execute", [deposit]);
      assert.equal((await getAccount(connection, spokeVault)).amount, AMOUNT);
      assert.equal((await getAccount(connection, source)).amount, 0n);
      record("legacy-deposit", execution, approval, 0, { delegateBump });

      await prepare();
      const value = relay(recipient, Buffer.alloc(0)),
        digest = relayHash(value);
      const [status, statusBump] = PublicKey.findProgramAddressSync([Buffer.from("fills"), digest], SPOKE);
      const [fillAuthority, authorityBump] = PublicKey.findProgramAddressSync(
        [Buffer.from("delegate"), hash(Buffer.concat([digest, u64(1), owner.toBuffer()]))],
        SPOKE
      );
      const approvalCu = await send("legacy-fill:approval", [
        createApproveCheckedInstruction(source, mint, fillAuthority, owner, AMOUNT, 6),
      ]);
      const executionCu = await send("legacy-fill:execute", [
        await spoke.methods
          .fillRelay([...digest], value, new BN(1), owner)
          .accountsStrict({
            ...base,
            signer: owner,
            instructionParams: SPOKE, // Anchor's sentinel for an absent optional account.
            delegate: fillAuthority,
            relayerTokenAccount: source,
            recipientTokenAccount: recipientAta,
            fillStatus: status,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .instruction(),
      ]);
      const filled = spoke.coder.accounts.decode(
        "fillStatusAccount",
        (await connection.getAccountInfo(status))!.data
      ) as { status: object; relayer: PublicKey };
      assert("filled" in filled.status);
      assert(filled.relayer.equals(owner));
      assert.equal((await getAccount(connection, recipientAta)).amount, AMOUNT);
      assert.equal((await getAccount(connection, source)).amount, 0n);
      record("legacy-fill", executionCu, approvalCu, 0, { statusBump, delegateBump: authorityBump });
      continue;
    }

    const remaining = [
      account(SPOKE),
      account(dispatch),
      account(state),
      account(eventAuthority),
      account(mint),
      account(TOKEN_PROGRAM_ID),
      account(vault, true),
      account(spokeVault, true),
      account(source, true),
      account(recipientAta, true),
      account(vaultAuthority),
      account(depositDelegate),
      account(fillDelegate),
      account(fillPayer, true),
      account(SystemProgram.programId),
    ];
    const baseMetas = [
      meta(state),
      meta(eventAuthority),
      meta(SPOKE),
      meta(mint),
      meta(TOKEN_PROGRAM_ID),
      meta(vault, true),
    ];
    const makePath = (commands: Command[]): Path => ({
      chainId: CHAIN_ID,
      salt: seed(`${sample}:path-salt`),
      message: tape(commands),
    });
    async function execute(
      name: Case,
      selected: Path,
      jit: Buffer[],
      funds: Buffer[],
      extra: AccountMeta[],
      approval = 0,
      details: Record<string, string | number> = {}
    ) {
      const params = executeParams(selected, pathId(selected), [], jit, funds);
      const discriminator = gateway.idl.accounts!.find(({ name }) => name === "executeParamsAccount")!.discriminator;
      const digest = Buffer.from(sha256(Buffer.concat([Buffer.from(discriminator), params])), "hex");
      const [buffer, bufferBump] = PublicKey.findProgramAddressSync(
        [Buffer.from("execute_params"), owner.toBuffer(), digest],
        GATEWAY
      );
      let bufferCu = await send(`${name}:buffer-init`, [
        await gateway.methods
          .initializeExecuteParams([...digest], params.length)
          .accountsStrict({ submitter: owner, executeParams: buffer, systemProgram: SystemProgram.programId })
          .instruction(),
      ]);
      for (let offset = 0; offset < params.length; offset += 800)
        bufferCu += await send(`${name}:buffer-write`, [
          await gateway.methods
            .writeExecuteParamsFragment([...digest], offset, params.subarray(offset, offset + 800))
            .accountsStrict({ submitter: owner, executeParams: buffer })
            .instruction(),
        ]);
      const execution = await send(`${name}:execute`, [
        await gateway.methods
          .execute(null)
          .accountsStrict({
            localFundingSigner: owner, // Required signer slot, even when StepDelegate authorizes the funding.
            submitter: owner,
            executeParams: buffer,
            config: pda(GATEWAY, Buffer.from("config")),
            eventAuthority: pda(GATEWAY, Buffer.from("__event_authority")),
            program: GATEWAY,
          })
          .remainingAccounts([...remaining, ...extra])
          .instruction(),
      ]);
      assert.equal(await connection.getAccountInfo(buffer), null, "successful execution closes parameter buffer");
      assert.equal((await getAccount(connection, vault)).amount, 0n);
      assert.equal((await getAccount(connection, source)).amount, 0n);
      record(name, execution, approval, bufferCu, {
        pathId: pathId(selected).toString("hex"),
        paramsBytes: params.length,
        bufferBump,
        ...details,
      });
    }
    await prepare();
    const depositInput = spoke.coder.types.encode("v5AdapterInput", {
      depositV1: [
        {
          depositParams: {
            depositor: owner,
            recipient,
            inputToken: mint,
            outputToken: mint,
            inputAmount: new BN(AMOUNT.toString()),
            outputAmount: [...word(AMOUNT)],
            destinationChainId: new BN(1),
            exclusiveRelayer: PublicKey.default,
            depositNonce: new BN(sample),
            quoteTimestamp: NOW,
            fillDeadline: NOW + 600,
            exclusivityParameter: 0,
          },
          dstStepId: [...seed(`${sample}:destination-root`)],
          inputAmountMode: { inputVaultBalance: { bips: 10000 } },
          modificationRules: { authority: Array(20).fill(0), allowOutputAmount: false, allowExclusiveRelayer: false },
        },
      ],
    });
    const sourcePath = makePath([
      approve(mint, depositDelegate),
      {
        op: OP.ADAPTER_CALL,
        input: call(SPOKE, [...baseMetas, meta(spokeVault, true), meta(depositDelegate)], depositInput),
      },
    ]);
    const [fundingDelegate, fundingBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("step_funding"), pathId(sourcePath), mint.toBuffer(), u64(FUNDING_DEADLINE)],
      GATEWAY
    );
    const approvalCu = await send("v5-deposit:approval", [
      createApproveCheckedInstruction(source, mint, fundingDelegate, owner, AMOUNT, 6),
    ]);
    await execute(
      "v5-deposit",
      sourcePath,
      [],
      [funding(source, mint, AMOUNT, FUNDING_DEADLINE)],
      [account(fundingDelegate)],
      approvalCu,
      { fundingBump }
    );
    assert.equal((await getAccount(connection, spokeVault)).amount, AMOUNT);
    assert.equal((await getAccount(connection, source)).delegate, null);
    for (const inPlace of [false, true]) {
      await prepare();
      const who = inPlace ? vaultAuthority : recipient;
      const fillInput = spoke.coder.types.encode("v5AdapterInput", {
        fillV1: [{ recipient: who, outputToken: mint, minOutputAmount: new BN(AMOUNT.toString()) }],
      });
      const command = {
        op: OP.ADAPTER_CALL | OP.JIT,
        input: call(
          SPOKE,
          [
            ...baseMetas,
            ...(!inPlace ? [meta(recipientAta, true), meta(fillDelegate)] : []),
            injected(),
            injected(),
            meta(SystemProgram.programId),
          ],
          fillInput
        ),
      };
      const selected = makePath(
        inPlace ? canonicalInPlace(command, mint, AMOUNT, recipient) : [approve(mint, fillDelegate), command]
      );
      const value = relay(who, Buffer.concat([PREFIX, pathId(selected)])),
        digest = relayHash(value);
      const [status, statusBump] = PublicKey.findProgramAddressSync([Buffer.from("fills"), digest], SPOKE);
      const payerBefore = await connection.getBalance(fillPayer);
      const jit = spoke.coder.types.encode("v5FillJit", {
        relayData: value,
        repaymentChainId: new BN(1),
        repaymentAddress: owner,
      });
      await execute(
        inPlace ? "v5-inplace-fill" : "v5-external-fill",
        selected,
        [Buffer.concat([status.toBuffer(), fillPayer.toBuffer(), jit])],
        [funding(source, mint, AMOUNT)],
        [account(status, true)],
        0,
        { statusBump }
      );
      const filled = spoke.coder.accounts.decode(
        "fillStatusAccount",
        (await connection.getAccountInfo(status))!.data
      ) as { status: object; relayer: PublicKey };
      assert("filled" in filled.status);
      assert(filled.relayer.equals(fillPayer));
      assert.equal((await getAccount(connection, recipientAta)).amount, AMOUNT);
      assert.equal((await getAccount(connection, vault)).delegate, null);
      assert.equal(
        payerBefore - (await connection.getBalance(fillPayer)),
        (await connection.getAccountInfo(status))!.lamports
      );
    }
  }
  writeFileSync(
    path.join(output, `${mode}.json`),
    JSON.stringify({ runtime: runtimeInfo, measurements }, null, 2) + "\n"
  );
}
main().then(
  () => process.exit(0),
  (error) => {
    console.error(error);
    process.exit(1);
  }
);
