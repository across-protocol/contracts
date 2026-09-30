// Raydium CPMM source fixture. No mainnet state or privileged production keys.
import { AnchorProvider, BN, BorshAccountsCoder, Idl, Program } from "@coral-xyz/anchor";
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
  SYSVAR_CLOCK_PUBKEY,
  SYSVAR_RENT_PUBKEY,
  Transaction,
} from "@solana/web3.js";
import { writeFileSync } from "fs";
import path from "path";
import swapIdl from "./fixtures/raydium_cp_swap.244e1241.json";
import { call, Command, OP, pda, u16, u32 } from "./reference";

export const SWAP_COMMIT = "244e1241f3c8d90eb93f176dfbc35f2605ec5a5c";
export const SWAP_PROGRAM = new PublicKey("CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C");
const config = pda(SWAP_PROGRAM, Buffer.from("amm_config"), Buffer.from([0, 0]));
const authority = pda(SWAP_PROGRAM, Buffer.from("vault_and_lp_mint_auth_seed"));
const feeAccount = new PublicKey("DNXgeM9EiiaAbaWvwjHj9fQQLAX5ZsfHyvmYUNRAdNC8");

// Seed only admin configuration and the fee receiver. Pool creation, liquidity
// deposits and swaps all execute the unmodified upstream program.
export async function swapGenesis(work: string): Promise<string[]> {
  const idl = swapIdl as Idl;
  if (idl.address !== SWAP_PROGRAM.toBase58()) throw new Error("IDL must match the pinned Raydium program");
  const configData = await new BorshAccountsCoder(idl).encode("AmmConfig", {
    bump: PublicKey.findProgramAddressSync([Buffer.from("amm_config"), Buffer.from([0, 0])], SWAP_PROGRAM)[1],
    disable_create_pool: false,
    index: 0,
    trade_fee_rate: new BN(2500), // 0.25% trade fee; other fees zero.
    protocol_fee_rate: new BN(0),
    fund_fee_rate: new BN(0),
    create_pool_fee: new BN(0),
    protocol_owner: PublicKey.default,
    fund_owner: PublicKey.default,
    creator_fee_rate: new BN(0),
    padding: Array.from({ length: 15 }, () => new BN(0)),
  });
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
  const program = new Program(swapIdl as Idl, provider);
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
  const initialize = await program.methods
    .initialize(new BN(liquidity.toString()), new BN(liquidity.toString()), new BN(0))
    .accountsStrict({
      creator: wallet.publicKey,
      ammConfig: config,
      authority,
      poolState: pool,
      token0Mint: mint0,
      token1Mint: mint1,
      lpMint,
      creatorToken0: getAssociatedTokenAddressSync(mint0, wallet.publicKey),
      creatorToken1: getAssociatedTokenAddressSync(mint1, wallet.publicKey),
      creatorLpToken: getAssociatedTokenAddressSync(lpMint, wallet.publicKey),
      token0Vault: poolVault(mint0),
      token1Vault: poolVault(mint1),
      createPoolFee: feeAccount,
      observationState: observation,
      tokenProgram: TOKEN_PROGRAM_ID,
      token0Program: TOKEN_PROGRAM_ID,
      token1Program: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
      rent: SYSVAR_RENT_PUBKEY,
    })
    .instruction();
  await provider.sendAndConfirm(new Transaction().add(initialize));
  // initialize sets open_time to clock + 1. Read the same Clock sysvar as the program;
  // block-time RPC lookups can fail on skipped slots.
  const clockTimestamp = async () => {
    const clock = await connection.getAccountInfo(SYSVAR_CLOCK_PUBKEY);
    if (!clock || clock.data.length !== 40) throw new Error("Invalid Clock sysvar");
    return clock.data.readBigInt64LE(32);
  };
  const initializedTime = await clockTimestamp();
  for (let n = 0; n < 100; n++) {
    if ((await clockTimestamp()) > initializedTime + 1n) break;
    if (n === 99) throw new Error("Raydium pool did not reach its open time");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const swapInstruction = (minimumOutput: bigint) =>
    program.methods
      .swapBaseInput(new BN(0), new BN(minimumOutput.toString()))
      .accountsStrict({
        payer: executorAuthority,
        authority,
        ammConfig: config,
        poolState: pool,
        inputTokenAccount: inputVault,
        outputTokenAccount: outputVault,
        inputVault: poolVault(inputMint),
        outputVault: poolVault(outputMint),
        inputTokenProgram: TOKEN_PROGRAM_ID,
        outputTokenProgram: TOKEN_PROGRAM_ID,
        inputTokenMint: inputMint,
        outputTokenMint: outputMint,
        observationState: observation,
      })
      .instruction();
  // Gateway BalanceSub patches amount_in. Keep its offset tied to the pinned IDL layout.
  const swapDefinition = program.idl.instructions.find((ix) => ix.name === "swapBaseInput");
  if (
    swapDefinition?.discriminator.length !== 8 ||
    swapDefinition.args[0]?.name !== "amountIn" ||
    swapDefinition.args[0]?.type !== "u64"
  )
    throw new Error("Unexpected Raydium amount_in layout");
  const substitution = Buffer.concat([inputMint.toBuffer(), u16(10000), u32(8)]);
  const swap = async (minimumOutput: bigint): Promise<Command> => {
    const ix = await swapInstruction(minimumOutput);
    const metas = ix.keys.map(({ pubkey, isWritable, isSigner }) => ({
      pubkey,
      flags: Number(isWritable) | (Number(isSigner) << 1),
    }));
    return { op: OP.CALL, input: call(ix.programId, metas, ix.data, [substitution]) };
  };
  const extra = [
    ...(await swapInstruction(0n)).keys.map((key) => ({ ...key, isSigner: false })),
    { pubkey: program.programId, isSigner: false, isWritable: false },
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
