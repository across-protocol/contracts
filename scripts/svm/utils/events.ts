// Internal operational inspection helpers. Production indexing belongs in the SDK.
import { Program, utils } from "@anchor-lang/core";
import { Connection, PublicKey, VersionedTransactionResponse } from "@solana/web3.js";

const CPI_EVENT_PREFIX = Buffer.from("e445a52e51cb9a1d", "hex");

export function decodeCpiEvents(tx: VersionedTransactionResponse, program: Program<any>) {
  if (!tx.meta || tx.meta.err) return [];
  const keys = tx.transaction.message.getAccountKeys({ accountKeysFromLookups: tx.meta.loadedAddresses });
  const [authority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId);
  const events = [];
  for (const block of tx.meta.innerInstructions ?? []) {
    for (const ix of block.instructions) {
      if (
        !keys.get(ix.programIdIndex)?.equals(program.programId) ||
        ix.accounts.length !== 1 ||
        !keys.get(ix.accounts[0])?.equals(authority)
      )
        continue;
      try {
        const data = Buffer.from(utils.bytes.bs58.decode(ix.data));
        if (!data.subarray(0, 8).equals(CPI_EVENT_PREFIX)) continue;
        const event = program.coder.events.decode(data.subarray(8).toString("base64"));
        if (event) events.push(event);
      } catch {
        // Unknown or malformed event data is not a decoded event.
      }
    }
  }
  return events;
}

export async function* readEventsForAddress(connection: Connection, program: Program<any>, address: PublicKey) {
  let before: string | undefined;
  while (true) {
    const page = await connection.getSignaturesForAddress(address, { before, limit: 1000 }, "confirmed");
    for (const signature of page) {
      if (signature.err) continue;
      const tx = await connection.getTransaction(signature.signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });
      if (!tx) continue;
      for (const event of decodeCpiEvents(tx, program))
        yield { ...event, signature: signature.signature, slot: tx.slot };
    }
    if (page.length < 1000) return;
    before = page[page.length - 1].signature;
  }
}

export async function readFillEventFromFillStatusPda(connection: Connection, program: Program<any>, pda: PublicKey) {
  // A close, failed fill, historical slow-fill request, or unrelated transaction can precede the fill in history.
  for await (const event of readEventsForAddress(connection, program, pda)) {
    if (event.name === "filledRelay") return event;
  }
  return null;
}
