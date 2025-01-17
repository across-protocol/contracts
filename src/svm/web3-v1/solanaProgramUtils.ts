import { BN, Idl, Program, utils, web3 } from "@coral-xyz/anchor";
import {
  ConfirmedSignatureInfo,
  Connection,
  Finality,
  Logs,
  PublicKey,
  SignaturesForAddressOptions,
} from "@solana/web3.js";
import { deserialize } from "borsh";
import { EventType } from "../../types/svm";
import { publicKeyToEvmAddress } from "./conversionUtils";

/**
 * Finds a program address with a given label and optional extra seeds.
 */
export function findProgramAddress(label: string, program: PublicKey, extraSeeds?: string[]) {
  const seeds: Buffer[] = [Buffer.from(utils.bytes.utf8.encode(label))];
  if (extraSeeds) {
    for (const extraSeed of extraSeeds) {
      if (typeof extraSeed === "string") {
        seeds.push(Buffer.from(utils.bytes.utf8.encode(extraSeed)));
      } else if (Array.isArray(extraSeed)) {
        seeds.push(Buffer.from(extraSeed));
      } else if (Buffer.isBuffer(extraSeed)) {
        seeds.push(extraSeed);
      } else {
        seeds.push((extraSeed as any).toBuffer());
      }
    }
  }
  const res = PublicKey.findProgramAddressSync(seeds, program);
  return { publicKey: res[0], bump: res[1] };
}

/**
 * Reads events from a transaction.
 */
export async function readEvents<IDL extends Idl = Idl>(
  connection: Connection,
  txSignature: string,
  programs: Program<IDL>[],
  commitment: Finality = "confirmed"
) {
  const txResult = await connection.getTransaction(txSignature, { commitment, maxSupportedTransactionVersion: 0 });

  if (txResult === null) return [];

  return processEventFromTx(txResult, programs);
}

/**
 * Processes events from a transaction.
 */
function processEventFromTx(txResult: web3.VersionedTransactionResponse, programs: Program<any>[]) {
  const eventAuthorities: Map<string, PublicKey> = new Map();
  for (const program of programs) {
    eventAuthorities.set(
      program.programId.toString(),
      findProgramAddress("__event_authority", program.programId).publicKey
    );
  }

  const events = [];

  // Resolve any potential addresses that were passed from address lookup tables.
  const messageAccountKeys = txResult.transaction.message.getAccountKeys({
    accountKeysFromLookups: txResult.meta?.loadedAddresses,
  });

  for (const ixBlock of txResult.meta?.innerInstructions ?? []) {
    for (const ix of ixBlock.instructions) {
      for (const program of programs) {
        const ixProgramId = messageAccountKeys.get(ix.programIdIndex);
        const singleIxAccount = ix.accounts.length === 1 ? messageAccountKeys.get(ix.accounts[0]) : undefined;
        if (
          ixProgramId !== undefined &&
          singleIxAccount !== undefined &&
          program.programId.equals(ixProgramId) &&
          eventAuthorities.get(ixProgramId.toString())?.equals(singleIxAccount)
        ) {
          const ixData = utils.bytes.bs58.decode(ix.data);
          const eventData = utils.bytes.base64.encode(Buffer.from(new Uint8Array(ixData).slice(8)));
          const event = program.coder.events.decode(eventData);
          events.push({
            program: program.programId,
            data: event?.data,
            name: event?.name,
          });
        }
      }
    }
  }
  return events;
}

/**
 * Helper function to wait for an event to be emitted. Should only be used in tests where txSignature is known to emit.
 */
export async function readEventsUntilFound<IDL extends Idl = Idl>(
  connection: Connection,
  txSignature: string,
  programs: Program<IDL>[]
) {
  const startTime = Date.now();
  let txResult = null;

  while (Date.now() - startTime < 5000) {
    // 5 seconds timeout to wait to find the event.
    txResult = await connection.getTransaction(txSignature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (txResult !== null) return processEventFromTx(txResult, programs);

    await new Promise((resolve) => setTimeout(resolve, 50)); // 50 ms delay between retries.
  }

  throw new Error("No event found within 5 seconds");
}

/**
 * Retrieves a specific event by name from a list of events.
 */
export function getEvent(events: any[], program: PublicKey, eventName: string) {
  for (const event of events) {
    if (event.name === eventName && program.toString() === event.program.toString()) {
      return event.data;
    }
  }
  throw new Error("Event " + eventName + " not found");
}

/**
 * Reads all events for a specific program.
 */
export async function readProgramEvents(
  connection: Connection,
  program: Program<any>,
  finality: Finality = "confirmed",
  options: SignaturesForAddressOptions = { limit: 1000 }
): Promise<EventType[]> {
  const allSignatures: ConfirmedSignatureInfo[] = [];

  // Fetch all signatures in sequential batches
  while (true) {
    const signatures = await connection.getSignaturesForAddress(program.programId, options, finality);
    allSignatures.push(...signatures);

    // Update options for the next batch. Set before to the last fetched signature.
    if (signatures.length > 0) {
      options = { ...options, before: signatures[signatures.length - 1].signature };
    }

    if (options.limit && signatures.length < options.limit) break; // Exit early if the number of signatures < limit
  }

  // Fetch events for all signatures in parallel
  const eventsWithSlots = await Promise.all(
    allSignatures.map(async (signature) => {
      const events = await readEvents(connection, signature.signature, [program], finality);
      return events.map((event) => ({
        ...event,
        confirmationStatus: signature.confirmationStatus || "Unknown",
        blockTime: signature.blockTime || 0,
        signature: signature.signature,
        slot: signature.slot,
        name: event.name || "Unknown",
      }));
    })
  );

  return eventsWithSlots.flat(); // Flatten the array of events & return.
}

/**
 * Subscribes to CPI events for a program.
 */
export async function subscribeToCpiEventsForProgram(
  connection: Connection,
  program: Program<any>,
  callback: (events: any[]) => void
) {
  const subscriptionId = connection.onLogs(
    new PublicKey(findProgramAddress("__event_authority", program.programId).publicKey.toString()),
    async (logs: Logs) => {
      callback(await readEvents(connection, logs.signature, [program], "confirmed"));
    },
    "confirmed"
  );

  return subscriptionId;
}

/**
 * Class for DepositId.
 */
class DepositId {
  value: Uint8Array; // Fixed-length array as Uint8Array

  constructor(properties: { value: Uint8Array }) {
    this.value = properties.value;
  }
}

/**
 * Borsh schema for deserializing DepositId.
 */
const depositIdSchema = new Map(
  [[DepositId, { kind: "struct", fields: [["value", [32]]] }]] // Fixed array [u8; 32]
);

/**
 * Parses depositId: checks if only the first 4 bytes are non-zero and returns a u32 or deserializes the full array.
 */
function parseDepositId(value: Uint8Array): string {
  const restAreZero = value.slice(4).every((byte) => byte === 0);

  if (restAreZero) {
    // Parse the first 4 bytes as a little-endian u32
    const u32Value = new DataView(value.buffer).getUint32(0, true); // true for little-endian
    return u32Value.toString();
  }

  // Deserialize the full depositId using the Borsh schema
  const depositId = deserialize(depositIdSchema, DepositId, Buffer.from(value));
  return new BN(depositId.value).toString();
}

/**
 * Stringifies a CPI event.
 */
export function stringifyCpiEvent(obj: any): any {
  if (obj?.constructor?.toString()?.includes("PublicKey")) {
    if (obj.toString().startsWith("111111111111")) {
      // First 12 bytes are 0 for EVM addresses.
      return publicKeyToEvmAddress(obj);
    }
    return obj.toString();
  } else if (BN.isBN(obj)) {
    return obj.toString();
  } else if (typeof obj === "bigint" && obj !== 0n) {
    return obj.toString();
  } else if (Array.isArray(obj) && obj.length == 32) {
    return Buffer.from(obj).toString("hex"); // Hex representation for fixed-length arrays
  } else if (Array.isArray(obj)) {
    return obj.map(stringifyCpiEvent);
  } else if (obj !== null && typeof obj === "object") {
    return Object.fromEntries(
      Object.entries(obj).map(([key, value]) => {
        if (key === "depositId" && Array.isArray(value) && value.length === 32) {
          // Parse depositId using the helper function
          const parsedValue = parseDepositId(new Uint8Array(value));
          return [key, parsedValue];
        }
        return [key, stringifyCpiEvent(value)];
      })
    );
  }
  return obj;
}
