import { Connection, Finality, SignaturesForAddressOptions, PublicKey, TransactionSignature } from "@solana/web3.js";
import { Program, utils, Idl } from "@coral-xyz/anchor";

// In-memory store for events
const eventStore = new Map<number, any[]>();

// Function to update the event store with all events using pagination
export async function update(
  connection: Connection,
  program: Program<any>,
  eventStore: Map<number, any[]>,
  options?: SignaturesForAddressOptions
) {
  let allEvents: any[] = [];
  options = options || { limit: 1000 }; // Default limit
  let signatures: any[] = [];

  // Fetch signatures in batches
  do {
    const fetchedSignatures = await connection.getSignaturesForAddress(program.programId, options);
    signatures = fetchedSignatures;

    // Fetch events for each signature
    for (const signature of signatures) {
      const txEvents = await readEvents(connection, signature.signature, [program]);
      allEvents.push(...txEvents);

      // Store events by slot number
      const slot = signature.slot; // Assuming signature object has a slot property
      if (!eventStore.has(slot)) {
        eventStore.set(slot, []);
      }
      eventStore.get(slot)?.push(...txEvents);
    }

    // Update options for the next batch
    if (signatures.length > 0) {
      options = {
        ...options,
        before: signatures[signatures.length - 1].signature, // Set before to the last fetched signature
      };
    }
  } while (signatures.length > 0);

  return allEvents;
}

export async function readProgramEvents(
  connection: Connection,
  program: Program<any>,
  eventStore: Map<number, any[]>,
  options?: SignaturesForAddressOptions,
  finality: Finality = "confirmed"
) {
  console.time("readProgramEvents Total Time");
  const events = await update(connection, program, eventStore, options); // Call the update function to store events
  console.timeEnd("readProgramEvents Total Time");
  return events;
}

// Helper method to query events by slot range and event name
export function queryEventsBySlotRange(startSlot: number, endSlot: number, eventName: string): any[] {
  let queriedEvents = [];
  for (let slot = startSlot; slot <= endSlot; slot++) {
    if (eventStore.has(slot)) {
      const eventsAtSlot = eventStore.get(slot);
      const filteredEvents = eventsAtSlot?.filter((event) => event.name === eventName);
      queriedEvents.push(...(filteredEvents ?? []));
    }
  }
  return queriedEvents;
}

export async function readEvents<IDL extends Idl = Idl>(
  connection: Connection,
  txSignature: string,
  programs: Program<IDL>[],
  commitment: Finality = "confirmed"
) {
  const txResult = await connection.getTransaction(txSignature, {
    commitment,
    maxSupportedTransactionVersion: 0,
  });

  let eventAuthorities = new Map();
  for (const program of programs) {
    eventAuthorities.set(
      program.programId.toString(),
      findProgramAddress("__event_authority", program.programId).publicKey.toString()
    );
  }

  let events: any[] = [];

  // TODO: Add support for version 0 transactions.
  if (!txResult || txResult.transaction.message.version !== "legacy") return events;

  for (const ixBlock of txResult.meta?.innerInstructions ?? []) {
    for (const ix of ixBlock.instructions) {
      for (const program of programs) {
        const programStr = program.programId.toString();
        if (
          ix.accounts.length === 1 &&
          (txResult.transaction.message as any).accountKeys[ix.programIdIndex].toString() === programStr &&
          (txResult.transaction.message as any).accountKeys[ix.accounts[0]].toString() ===
            eventAuthorities.get(programStr)
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
