import { Connection, Finality, SignaturesForAddressOptions, PublicKey, ConfirmedSignatureInfo } from "@solana/web3.js";
import { Program, utils, Idl } from "@coral-xyz/anchor";

export interface EventType {
  program: PublicKey;
  data: any;
  name: string;
  slot: number;
  confirmationStatus: string;
  blockTime: number;
  signature: string;
}

// Function to update the event store with all events using pagination
export async function update(connection: Connection, program: Program<any>, eventStore: Map<number, EventType[]>) {
  let options: SignaturesForAddressOptions = { limit: 1000 }; // Default max limit of 1000.

  let signatures: ConfirmedSignatureInfo[] = [];

  // Fetch signatures in batches
  do {
    const fetchedSignatures = await connection.getSignaturesForAddress(program.programId, options, "finalized");
    signatures = fetchedSignatures;

    // Fetch events for each signature in parallel
    const readEventsPromises = signatures.map(async (signature) => {
      const events = await readEvents(connection, signature.signature, [program]);
      return {
        events: events.map((event) => ({
          ...event,
          confirmationStatus: signature.confirmationStatus,
          blockTime: signature.blockTime,
          signature: signature.signature,
        })),
        slot: signature.slot,
      }; // Return events with associated slot
    });
    const eventsWithSlots = await Promise.all(readEventsPromises);

    // Flatten the array of events and store them by slot number
    for (const { events, slot } of eventsWithSlots) {
      const eventsWithSlot = events.map((event) => ({ ...event, slot }));

      if (!eventStore.has(slot)) {
        eventStore.set(slot, []);
      }

      // Append events only if the signature is not already present
      const existingEvents = eventStore.get(slot) || [];
      const newEvents = eventsWithSlot.filter(
        (event) => !existingEvents.some((existingEvent) => existingEvent.signature === event.signature)
      );

      eventStore.get(slot)?.push(...newEvents); // Store new events with slot
    }

    // Update options for the next batch. Set before to the last fetched signature.
    if (signatures.length > 0) options = { ...options, before: signatures[signatures.length - 1].signature };

    if (options.limit && signatures.length < options.limit) break; // Exit early if the number of signatures < limit
  } while (signatures.length > 0);
}

// Helper method to query events by event name and optional slot range. startSlot and endSlot are inclusive.
export function queryEventsBySlotRange(
  eventName: string,
  eventStore: Map<number, EventType[]>,
  startSlot?: number,
  endSlot?: number
): EventType[] {
  let queriedEvents = [];

  // Determine the range of slots to search
  const slots = Array.from(eventStore.keys());
  const minSlot = startSlot ?? Math.min(...slots);
  const maxSlot = endSlot ?? Math.max(...slots);

  for (let slot = minSlot; slot <= maxSlot; slot++) {
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
  const txResult = await connection.getTransaction(txSignature, { commitment, maxSupportedTransactionVersion: 0 });

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
