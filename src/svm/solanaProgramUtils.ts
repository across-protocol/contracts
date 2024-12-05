import { Idl, Program, utils } from "@coral-xyz/anchor";
import { Connection, Finality, Logs, PublicKey, SignaturesForAddressOptions } from "@solana/web3.js";

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
 * Reads events from a transaction involving specified programs.
 */
export async function readEvents<IDL extends Idl = Idl>(
  connection: Connection,
  txSignature: string,
  programs: Program<IDL>[],
  commitment: Finality = "confirmed"
): Promise<{ program: PublicKey; data: any; name: string | undefined }[]> {
  const txResult = await connection.getTransaction(txSignature, {
    commitment,
    maxSupportedTransactionVersion: 0,
  });

  if (txResult === null) return [];

  const eventAuthorities: Map<string, PublicKey> = new Map();
  for (const program of programs) {
    eventAuthorities.set(
      program.programId.toString(),
      findProgramAddress("__event_authority", program.programId).publicKey
    );
  }

  const events: { program: PublicKey; data: any; name: string | undefined }[] = [];

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
  options?: SignaturesForAddressOptions,
  finality: Finality = "confirmed"
) {
  const events: { program: PublicKey; data: any; name: string | undefined }[] = [];
  const pastSignatures = await connection.getSignaturesForAddress(program.programId, options, finality);

  for (const signature of pastSignatures) {
    events.push(...(await readEvents(connection, signature.signature, [program], finality)));
  }
  return events;
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
