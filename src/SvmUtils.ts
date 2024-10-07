//TODO: we will need to move this to a better location and integrate it more directly with other utils & files in time.
import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Layout } from "@solana/buffer-layout";
import { ethers } from "ethers";
import { PublicKey, Connection, Finality, SignaturesForAddressOptions, Logs } from "@solana/web3.js";

export function findProgramAddress(label: string, program: PublicKey, extraSeeds?: string[]) {
  const seeds: Buffer[] = [Buffer.from(anchor.utils.bytes.utf8.encode(label))];
  if (extraSeeds) {
    for (const extraSeed of extraSeeds) {
      if (typeof extraSeed === "string") {
        seeds.push(Buffer.from(anchor.utils.bytes.utf8.encode(extraSeed)));
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

export async function readEvents(
  connection: Connection,
  txSignature: string,
  programs: Program<anchor.Idl>[],
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
          const ixData = anchor.utils.bytes.bs58.decode(ix.data);
          const eventData = anchor.utils.bytes.base64.encode(Buffer.from(new Uint8Array(ixData).slice(8)));
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

export function getEvent(events: any[], program: PublicKey, eventName: string) {
  for (const event of events) {
    if (event.name === eventName && program.toString() === event.program.toString()) {
      return event.data;
    }
  }
  throw new Error("Event " + eventName + " not found");
}

export async function readProgramEvents(
  connection: Connection,
  program: Program<any>,
  options?: SignaturesForAddressOptions,
  finality: Finality = "confirmed"
) {
  let events = [];
  const pastSignatures = await connection.getSignaturesForAddress(program.programId, options, finality);

  for (const signature of pastSignatures) {
    events.push(...(await readEvents(connection, signature.signature, [program], finality)));
  }
  return events;
}

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

export const evmAddressToPublicKey = (address: string): PublicKey => {
  const bytes32Address = `0x000000000000000000000000${address.replace("0x", "")}`;
  return new PublicKey(ethers.utils.arrayify(bytes32Address));
};

// TODO: we are inconsistant with where we are placing some utils. we have some stuff here, some stuff that we might
// want to re-use within the test directory. more over, when moving things into the canonical across repo, we should
// re-use the test utils there.
export function calculateRelayHashUint8Array(relayData: any, chainId: anchor.BN): Uint8Array {
  const messageBuffer = Buffer.alloc(4);
  messageBuffer.writeUInt32LE(relayData.message.length, 0);

  const contentToHash = Buffer.concat([
    relayData.depositor.toBuffer(),
    relayData.recipient.toBuffer(),
    relayData.exclusiveRelayer.toBuffer(),
    relayData.inputToken.toBuffer(),
    relayData.outputToken.toBuffer(),
    relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayData.originChainId.toArrayLike(Buffer, "le", 8),
    new anchor.BN(relayData.depositId).toArrayLike(Buffer, "le", 4),
    relayData.fillDeadline.toArrayLike(Buffer, "le", 4),
    relayData.exclusivityDeadline.toArrayLike(Buffer, "le", 4),
    messageBuffer,
    relayData.message,
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  const relayHashBuffer = Buffer.from(relayHash.slice(2), "hex");
  return new Uint8Array(relayHashBuffer);
}

export const readUInt256BE = (buffer: Buffer): BigInt => {
  let result = BigInt(0);
  for (let i = 0; i < buffer.length; i++) {
    result = (result << BigInt(8)) + BigInt(buffer[i]);
  }
  return result;
};

// This is extended Anchor accounts coder to handle large account data that is required when passing instruction
// parameters from prefilled data account. Base implementation restricts the buffer to only 1000 bytes.
export class LargeAccountsCoder<A extends string = string> extends anchor.BorshAccountsCoder<A> {
  // Getter to access the private accountLayouts property from base class.
  private getAccountLayouts() {
    return (this as any).accountLayouts as Map<A, Layout<any>>;
  }

  public async encode<T = any>(accountName: A, account: T): Promise<Buffer> {
    const buffer = Buffer.alloc(10240); // We don't currently need anything above instruction data account reallocation limit.
    const layout = this.getAccountLayouts().get(accountName);
    if (!layout) {
      throw new Error(`Unknown account: ${accountName}`);
    }
    const len = layout.encode(account, buffer);
    const accountData = buffer.slice(0, len);
    const discriminator = this.accountDiscriminator(accountName);
    return Buffer.concat([discriminator, accountData]);
  }
}
