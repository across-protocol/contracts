// Raydium CPMM source fixture. No mainnet state or privileged production keys.
import { AnchorProvider } from "@coral-xyz/anchor";
import {
  AccountLayout,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  NATIVE_MINT,
  TOKEN_PROGRAM_ID,
  createMint,
  getAssociatedTokenAddressSync,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  SYSVAR_RENT_PUBKEY,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { createHash } from "crypto";
import { writeFileSync } from "fs";
import path from "path";
import { call, Command, discriminator, meta, OP, pda, u16, u32, u64 } from "./reference";

export const SWAP_COMMIT = "244e1241f3c8d90eb93f176dfbc35f2605ec5a5c";
export const SWAP_PROGRAM = new PublicKey("CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C");
const config = pda(SWAP_PROGRAM, Buffer.from("amm_config"), Buffer.from([0, 0]));
const authority = pda(SWAP_PROGRAM, Buffer.from("vault_and_lp_mint_auth_seed"));
const feeAccount = new PublicKey("DNXgeM9EiiaAbaWvwjHj9fQQLAX5ZsfHyvmYUNRAdNC8");

// Seed only admin configuration and the fee receiver. Pool creation, liquidity
// deposits and swaps all execute the unmodified upstream program.
export function swapGenesis(work: string): string[] {
  const configData = Buffer.alloc(236);
  createHash("sha256").update("account:AmmConfig").digest().copy(configData, 0, 0, 8);
  configData[8] = PublicKey.findProgramAddressSync([Buffer.from("amm_config"), Buffer.from([0, 0])], SWAP_PROGRAM)[1];
  configData.writeBigUInt64LE(2500n, 12); // 0.25% trade fee; other fees zero.
  const feeData = Buffer.alloc(AccountLayout.span);
  AccountLayout.encode(
    {
      mint: NATIVE_MINT,
      owner: authority,
      amount: 0n,
      delegateOption: 0,
      delegate: PublicKey.default,
      state: 1,
      isNativeOption: 1,
      isNative: 2_039_280n,
      delegatedAmount: 0n,
      closeAuthorityOption: 0,
      closeAuthority: PublicKey.default,
    },
    feeData
  );
  return [
    [config, SWAP_PROGRAM, configData],
    [feeAccount, TOKEN_PROGRAM_ID, feeData],
  ].flatMap(([key, owner, data]) => {
    const file = path.join(work, `${key}.json`);
    writeFileSync(
      file,
      JSON.stringify({
        pubkey: String(key),
        account: {
          lamports: 10_000_000,
          data: [(data as Buffer).toString("base64"), "base64"],
          owner: String(owner),
          executable: false,
          rentEpoch: 0,
        },
      })
    );
    return ["--account", String(key), file];
  });
}

export async function createSwapFixture(
  provider: AnchorProvider,
  wallet: Keypair,
  inputMint: PublicKey,
  inputVault: PublicKey,
  vaultAuthority: PublicKey,
  executorAuthority: PublicKey,
  recipient: PublicKey
) {
  const connection = provider.connection;
  const outputMint = await createMint(connection, wallet, wallet.publicKey, null, 6);
  const ata = async (mint: PublicKey, owner: PublicKey) =>
    (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, owner, true)).address;
  const [outputVault, recipientAta, inputSource, outputSource] = await Promise.all([
    ata(outputMint, vaultAuthority),
    ata(outputMint, recipient),
    ata(inputMint, wallet.publicKey),
    ata(outputMint, wallet.publicKey),
  ]);
  const liquidity = 1_000_000_000n;
  await mintTo(connection, wallet, inputMint, inputSource, wallet, liquidity);
  await mintTo(connection, wallet, outputMint, outputSource, wallet, liquidity);
  const [mint0, mint1] = [inputMint, outputMint].sort((a, b) => Buffer.compare(a.toBuffer(), b.toBuffer()));
  const pool = pda(SWAP_PROGRAM, Buffer.from("pool"), config.toBuffer(), mint0.toBuffer(), mint1.toBuffer());
  const poolVault = (mint: PublicKey) => pda(SWAP_PROGRAM, Buffer.from("pool_vault"), pool.toBuffer(), mint.toBuffer());
  const lpMint = pda(SWAP_PROGRAM, Buffer.from("pool_lp_mint"), pool.toBuffer());
  const observation = pda(SWAP_PROGRAM, Buffer.from("observation"), pool.toBuffer());
  const keys = [
    { pubkey: wallet.publicKey, isSigner: true, isWritable: true },
    ...[
      config,
      authority,
      pool,
      mint0,
      mint1,
      lpMint,
      getAssociatedTokenAddressSync(mint0, wallet.publicKey),
      getAssociatedTokenAddressSync(mint1, wallet.publicKey),
      getAssociatedTokenAddressSync(lpMint, wallet.publicKey),
      poolVault(mint0),
      poolVault(mint1),
      feeAccount,
      observation,
      TOKEN_PROGRAM_ID,
      TOKEN_PROGRAM_ID,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID,
      SystemProgram.programId,
      SYSVAR_RENT_PUBKEY,
    ].map((pubkey, i) => ({ pubkey, isSigner: false, isWritable: [2, 5, 6, 7, 8, 9, 10, 11, 12].includes(i) })),
  ];
  await provider.sendAndConfirm(
    new Transaction().add(
      new TransactionInstruction({
        programId: SWAP_PROGRAM,
        keys,
        data: Buffer.concat([discriminator("initialize"), u64(liquidity), u64(liquidity), u64(0)]),
      })
    )
  );
  // initialize sets open_time to clock + 1. Wait for on-chain time, not wall time.
  const initializedSlot = await connection.getSlot();
  const initializedTime = (await connection.getBlockTime(initializedSlot))!;
  for (let n = 0; n < 100; n++) {
    if (((await connection.getBlockTime(await connection.getSlot())) ?? 0) > initializedTime + 1) break;
    if (n === 99) throw new Error("Raydium pool did not reach its open time");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const metas = [
    { pubkey: executorAuthority, flags: 2 },
    meta(authority),
    meta(config),
    meta(pool, true),
    meta(inputVault, true),
    meta(outputVault, true),
    meta(poolVault(inputMint), true),
    meta(poolVault(outputMint), true),
    meta(TOKEN_PROGRAM_ID),
    meta(TOKEN_PROGRAM_ID),
    meta(inputMint),
    meta(outputMint),
    meta(observation, true),
  ];
  const swap = (minimumOutput: bigint): Command => {
    const data = Buffer.concat([discriminator("swap_base_input"), u64(0), u64(minimumOutput)]);
    // CALL's BalanceSub writes the entire live input-vault amount at byte 8.
    const substitution = Buffer.concat([inputMint.toBuffer(), u16(10000), u32(8)]);
    return { op: OP.CALL, input: call(SWAP_PROGRAM, metas, data, [substitution]) };
  };
  const extra = [
    ...metas.map((m) => ({ pubkey: m.pubkey, isSigner: false, isWritable: !!(m.flags & 1) })),
    { pubkey: SWAP_PROGRAM, isSigner: false, isWritable: false },
    { pubkey: recipientAta, isSigner: false, isWritable: true },
  ];
  return {
    outputMint,
    outputVault,
    recipientAta,
    pool,
    observation,
    poolInput: poolVault(inputMint),
    poolOutput: poolVault(outputMint),
    swap,
    extra,
  };
}
