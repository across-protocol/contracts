import { strict as assert } from "assert";
import {
  AddressLookupTableAccount,
  ComputeBudgetProgram,
  Connection,
  Keypair,
  TransactionInstruction,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import { appendFileSync } from "fs";
import { MAINNET_GENESIS } from "./config";
export type TxMeasurement = {
  flow: string;
  phase: string;
  signature: string;
  simulatedCu: number;
  consumedCu: number;
  computeUnitLimit: number;
  signatureCount: number;
  bytes: number;
  writableAccounts: string[];
  feeLamports: number;
};
export function paddedLimit(units: number, marginBps: number) {
  assert(Number.isSafeInteger(units) && units > 0, "Invalid simulated CU");
  assert(Number.isSafeInteger(marginBps) && marginBps >= 0 && marginBps <= 10000, "Margin must be 0..10000 bps");
  const limit = Math.ceil((units * (10000 + marginBps)) / 10000);
  assert(limit <= 1_400_000, "Padded transaction exceeds the CU ceiling; split or change the transaction");
  return limit;
}
export function assertLoopback(url: string) {
  const parsed = new URL(url);
  assert(
    parsed.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(parsed.hostname),
    "Transaction submission is restricted to local loopback RPC"
  );
}
export class Recorder {
  readonly connection: Connection;
  readonly transactions: TxMeasurement[] = [];
  constructor(
    url: string,
    readonly wallet: Keypair,
    readonly receiptFile: string,
    readonly marginBps: number
  ) {
    assertLoopback(url);
    this.connection = new Connection(url, "confirmed");
  }
  async verifyLocal() {
    assert.notEqual(await this.connection.getGenesisHash(), MAINNET_GENESIS, "Refuse mainnet submission");
  }
  async send(
    flow: string,
    phase: string,
    instructions: TransactionInstruction[],
    tables: AddressLookupTableAccount[] = []
  ) {
    const blockhash = await this.connection.getLatestBlockhash();
    const make = (limit: number) =>
      new VersionedTransaction(
        new TransactionMessage({
          payerKey: this.wallet.publicKey,
          recentBlockhash: blockhash.blockhash,
          instructions: [
            ComputeBudgetProgram.setComputeUnitLimit({ units: limit }),
            ComputeBudgetProgram.setComputeUnitPrice({ microLamports: 0 }),
            ...instructions,
          ],
        }).compileToV0Message(tables)
      );
    const high = make(1_400_000);
    high.sign([this.wallet]);
    const simulation = await this.connection.simulateTransaction(high, { sigVerify: true, commitment: "confirmed" });
    assert.equal(
      simulation.value.err,
      null,
      `${flow}:${phase}: ${JSON.stringify(simulation.value.err)}\n${simulation.value.logs?.join("\n")}`
    );
    const simulatedCu = simulation.value.unitsConsumed!;
    const limit = paddedLimit(simulatedCu, this.marginBps);
    const tx = make(limit);
    tx.sign([this.wallet]);
    const bytes = tx.serialize();
    assert(bytes.length <= 1232, "Transaction exceeds packet limit");
    const signature = await this.connection.sendRawTransaction(bytes, { skipPreflight: false });
    // Poll confirmed receipts directly; websocket subscriptions can outlive a short-lived validator.
    const deadline = Date.now() + 120_000;
    while (Date.now() < deadline) {
      const receipt = await this.connection.getTransaction(signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });
      if (receipt) {
        assert.equal(receipt.meta?.err, null);
        const consumedCu = receipt.meta?.computeUnitsConsumed!;
        assert(Number.isSafeInteger(consumedCu) && consumedCu > 0 && consumedCu <= limit);
        const keys = tx.message.getAccountKeys({ addressLookupTableAccounts: tables });
        const writableAccounts = Array.from({ length: keys.length }, (_, i) => i)
          .filter((i) => tx.message.isAccountWritable(i))
          .map((i) => keys.get(i)!.toBase58())
          .sort();
        const row = {
          flow,
          phase,
          signature,
          simulatedCu,
          consumedCu,
          computeUnitLimit: limit,
          signatureCount: tx.message.header.numRequiredSignatures,
          bytes: bytes.length,
          writableAccounts,
          feeLamports: receipt.meta!.fee,
        };
        this.transactions.push(row);
        appendFileSync(this.receiptFile, JSON.stringify({ ...row, receipt }) + "\n");
        return row;
      }
      await new Promise((r) => setTimeout(r, 250));
    }
    throw new Error(`${flow}:${phase}: confirmed receipt unavailable for ${signature}`);
  }
}
