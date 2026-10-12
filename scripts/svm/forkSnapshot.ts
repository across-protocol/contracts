// Read-only mainnet capture; all edits are applied to separate local genesis files.
import { strict as assert } from "assert";
import { Program, Idl } from "@anchor-lang/core";
import { AccountInfo, Connection, PublicKey, SystemProgram } from "@solana/web3.js";
import {
  AccountLayout,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  NATIVE_MINT,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { createHash } from "crypto";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  CPMM,
  POOL,
  STATE,
  SPOKE,
  GATEWAY,
  MINTS,
  VAULT_AUTHORITY,
  LOADER,
  FEATURES,
  MAINNET_GENESIS,
  payer,
  recipient,
  poolKeys,
} from "../../test/svm-gateway/fork/config";
import { pda } from "../../test/svm-gateway/wire";
export const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");
export type StoredAccount = {
  lamports: number;
  owner: string;
  executable: boolean;
  rentEpoch: number;
  data: [string, string];
};
export type Snapshot = {
  capturedAt: string;
  slot: number;
  genesisHash: string;
  accounts: Record<string, StoredAccount | null>;
  activeFeatures: string[];
  gatewayIdl?: Idl;
  programs: Record<string, { owner: string; programData?: string; sha256: string }>;
};
const store = (a: AccountInfo<Buffer>): StoredAccount => ({
  ...a,
  owner: a.owner.toBase58(),
  rentEpoch: a.rentEpoch ?? 0,
  data: [a.data.toString("base64"), "base64"],
});
export async function captureSnapshot(url: string, output: string): Promise<Snapshot> {
  const connection = new Connection(url, { commitment: "finalized", disableRetryOnRateLimit: true });
  // Sanitize SDK errors at the RPC boundary: provider URLs may contain credentials.
  try {
    const genesisHash = await connection.getGenesisHash();
    assert.equal(genesisHash, MAINNET_GENESIS, "Source must be Solana mainnet");
    const pool = await connection.getAccountInfo(POOL);
    assert(pool && pool.owner.equals(CPMM));
    const keys = poolKeys(pool.data);
    assert(keys.mint0.equals(NATIVE_MINT) && keys.mint1.equals(MINTS[0]), "Expected WSOL/USDC pool");
    const programIds = [GATEWAY, CPMM, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID];
    const programs = await connection.getMultipleAccountsInfo(programIds);
    const addresses = [
      POOL,
      ...Object.values(keys),
      STATE,
      pda(GATEWAY, Buffer.from("config")),
      ...MINTS.flatMap((m) => [
        m,
        getAssociatedTokenAddressSync(m, VAULT_AUTHORITY, true),
        getAssociatedTokenAddressSync(m, STATE, true),
      ]),
      ...programIds,
    ];
    for (const a of programs) {
      assert(a?.executable, "Missing executable");
      if (a.owner.equals(LOADER)) {
        assert.equal(a.data.readUInt32LE(0), 2);
        addresses.push(new PublicKey(a.data.subarray(4, 36)));
      }
    }
    const unique = [...new Map(addresses.map((a) => [a.toBase58(), a])).values()];
    // One bank context for all mutable pool, vault and program data accounts.
    const response = await connection.getMultipleAccountsInfoAndContext(unique);
    const accounts = Object.fromEntries(
      unique.map((a, i) => [a.toBase58(), response.value[i] ? store(response.value[i]!) : null])
    );
    const featureAccounts = await connection.getProgramAccounts(FEATURES);
    const activeFeatures = featureAccounts
      .filter((a) => a.account.data[0] === 1 && Number(a.account.data.readBigUInt64LE(1)) <= response.context.slot)
      .map((a) => a.pubkey.toBase58())
      .sort();
    const binaries: Snapshot["programs"] = {};
    for (const id of programIds) {
      const account = accounts[id.toBase58()];
      assert(account?.executable);
      let data = Buffer.from(account.data[0], "base64"),
        programData: string | undefined;
      if (account.owner === LOADER.toBase58()) {
        programData = new PublicKey(data.subarray(4, 36)).toBase58();
        const pd = accounts[programData];
        assert(pd && pd.owner === LOADER.toBase58());
        data = Buffer.from(pd.data[0], "base64");
        assert.equal(data.readUInt32LE(0), 3);
        data = data.subarray(45);
      }
      binaries[id.toBase58()] = { owner: account.owner, programData, sha256: sha256(data) };
    }
    const gatewayIdl = await Program.fetchIdl(GATEWAY, { connection });
    assert(gatewayIdl && gatewayIdl.address === GATEWAY.toBase58(), "Missing deployed Gateway IDL");
    const snapshot = {
      gatewayIdl,
      capturedAt: new Date().toISOString(),
      slot: response.context.slot,
      genesisHash,
      accounts,
      activeFeatures,
      programs: binaries,
    };
    writeFileSync(output, JSON.stringify(snapshot, null, 2) + "\n");
    return snapshot;
  } catch {
    throw new Error(
      "Mainnet snapshot capture failed (RPC details redacted); check provider access and expected account layouts"
    );
  }
}
export function readSnapshot(file: string): Snapshot {
  const s: Snapshot = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(s.genesisHash, MAINNET_GENESIS);
  assert(Number.isSafeInteger(s.slot) && s.slot > 0);
  for (const [address, a] of Object.entries(s.accounts)) {
    new PublicKey(address);
    if (a) {
      new PublicKey(a.owner);
      assert.equal(a.data[1], "base64");
    }
  }
  return s;
}
export function genesis(snapshot: Snapshot, directory: string, sample: number) {
  mkdirSync(directory, { recursive: true });
  const accounts = structuredClone(snapshot.accounts);
  const patches: { address: string; reason: string; before: string | null; after: string }[] = [];
  const put = (key: PublicKey, account: StoredAccount, reason: string) => {
    const address = key.toBase58();
    patches.push({
      address,
      reason,
      before: accounts[address] ? sha256(JSON.stringify(accounts[address])) : null,
      after: sha256(JSON.stringify(account)),
    });
    accounts[address] = account;
  };
  for (const program of Object.values(snapshot.programs)) {
    if (!program.programData) continue;
    const original = accounts[program.programData];
    assert(original && original.owner === LOADER.toBase58());
    const bytes = Buffer.from(original.data[0], "base64");
    assert.equal(bytes.readUInt32LE(0), 3);
    bytes.writeBigUInt64LE(0n, 4);
    put(
      new PublicKey(program.programData),
      { ...original, data: [bytes.toString("base64"), "base64"] },
      "Reset ProgramData deployment slot to local genesis; executable bytes and upgrade authority unchanged"
    );
  }
  const state = accounts[STATE.toBase58()];
  assert(state && state.owner === SPOKE.toBase58());
  const data = Buffer.from(state.data[0], "base64");
  assert.equal(data.length, 114);
  assert.equal(data.readBigUInt64LE(42), 0n);
  data[8] = 0;
  data[9] = 0;
  put(
    STATE,
    { ...state, data: [data.toString("base64"), "base64"] },
    "Clear paused_deposits and paused_fills in local genesis only; retain owner, chain ID, seed and other state"
  );
  const token = (mint: PublicKey, owner: PublicKey, amount: bigint): StoredAccount => {
    const data = Buffer.alloc(AccountLayout.span);
    const native = mint.equals(NATIVE_MINT);
    AccountLayout.encode(
      {
        mint,
        owner,
        amount,
        delegateOption: 0,
        delegate: PublicKey.default,
        state: 1,
        isNativeOption: native ? 1 : 0,
        isNative: native ? 2039280n : 0n,
        delegatedAmount: 0n,
        closeAuthorityOption: 0,
        closeAuthority: PublicKey.default,
      },
      data
    );
    return {
      lamports: 2039280 + (native ? Number(amount) : 0),
      owner: TOKEN_PROGRAM_ID.toBase58(),
      executable: false,
      rentEpoch: 0,
      data: [data.toString("base64"), "base64"],
    };
  };
  const wallet = payer(sample).publicKey;
  put(
    wallet,
    {
      lamports: 100_000_000_000,
      owner: SystemProgram.programId.toBase58(),
      executable: false,
      rentEpoch: 0,
      data: ["", "base64"],
    },
    "Synthetic local fee payer; no production key"
  );
  for (const mint of MINTS) {
    for (const owner of [wallet, recipient(sample).publicKey, VAULT_AUTHORITY]) {
      const amount = owner.equals(wallet) ? 10_000_000_000n : 0n;
      put(
        getAssociatedTokenAddressSync(mint, owner, true),
        token(mint, owner, amount),
        owner.equals(VAULT_AUTHORITY)
          ? "Empty Gateway vault and clear allowances for isolated balance-based funding/delivery"
          : "Synthetic local source/recipient ATA; balances are test inventory"
      );
    }
    const vault = getAssociatedTokenAddressSync(mint, STATE, true);
    if (!accounts[vault.toBase58()]) put(vault, token(mint, STATE, 0n), "Provision absent Spoke ATA locally");
  }
  const rentPayer = pda(SPOKE, Buffer.from("v5_fill_payer"), wallet.toBuffer());
  put(
    rentPayer,
    {
      lamports: 100_000_000,
      owner: SystemProgram.programId.toBase58(),
      executable: false,
      rentEpoch: 0,
      data: ["", "base64"],
    },
    "Synthetic local V5 fill rent float"
  );
  for (const [pubkey, account] of Object.entries(accounts))
    if (account)
      writeFileSync(
        path.join(directory, pubkey + ".json"),
        JSON.stringify({ pubkey, account: { ...account, rentEpoch: 0 } })
      );
  writeFileSync(path.join(path.dirname(directory), `patches-${sample}.json`), JSON.stringify(patches, null, 2) + "\n");
  return ["--account-dir", directory];
}
