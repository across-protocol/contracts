//TODO: we will need to move this to a better location and integrate it more directly with other utils & files in time.
// eslint-disable-next-line node/no-extraneous-import
import * as borsh from "@coral-xyz/borsh";
import bs58 from "bs58";
import { Program, BN, utils, BorshAccountsCoder, Idl, web3 } from "@coral-xyz/anchor";
import { IdlCoder } from "@coral-xyz/anchor/dist/cjs/coder/borsh/idl";
import { IdlTypeDef } from "@coral-xyz/anchor/dist/cjs/idl";
import { Layout } from "buffer-layout";
import { ethers } from "ethers";
import {
  PublicKey,
  Connection,
  Finality,
  SignaturesForAddressOptions,
  Logs,
  TransactionInstruction,
  Message,
  MessageHeader,
  MessageAccountKeys,
  MessageCompiledInstruction,
  CompiledInstruction,
  Keypair,
  AddressLookupTableProgram,
  VersionedTransaction,
  TransactionMessage,
  ConfirmedSignatureInfo,
} from "@solana/web3.js";

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

// Helper function to wait for an event to be emitted. Should only be used in tests where txSignature is known to emit.
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

export function getEvent(events: any[], program: PublicKey, eventName: string) {
  for (const event of events) {
    if (event.name === eventName && program.toString() === event.program.toString()) {
      return event.data;
    }
  }
  throw new Error("Event " + eventName + " not found");
}

export interface EventType {
  program: PublicKey;
  data: any;
  name: string;
  slot: number;
  confirmationStatus: string;
  blockTime: number;
  signature: string;
}

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

// TODO: we are inconsistent with where we are placing some utils. we have some stuff here, some stuff that we might
// want to re-use within the test directory. more over, when moving things into the canonical across repo, we should
// re-use the test utils there.
export function calculateRelayHashUint8Array(relayData: any, chainId: BN): Uint8Array {
  const contentToHash = Buffer.concat([
    relayData.depositor.toBuffer(),
    relayData.recipient.toBuffer(),
    relayData.exclusiveRelayer.toBuffer(),
    relayData.inputToken.toBuffer(),
    relayData.outputToken.toBuffer(),
    relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayData.depositId),
    new BN(relayData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    hashNonEmptyMessage(relayData.message), // Replace with hash of message, so that relay hash can be recovered from event.
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  const relayHashBuffer = Buffer.from(relayHash.slice(2), "hex");
  return new Uint8Array(relayHashBuffer);
}

// Same method as above, but message in the relayData is already hashed, as fetched from fill events.
export function calculateRelayEventHashUint8Array(relayEventData: any, chainId: BN): Uint8Array {
  const contentToHash = Buffer.concat([
    relayEventData.depositor.toBuffer(),
    relayEventData.recipient.toBuffer(),
    relayEventData.exclusiveRelayer.toBuffer(),
    relayEventData.inputToken.toBuffer(),
    relayEventData.outputToken.toBuffer(),
    relayEventData.inputAmount.toArrayLike(Buffer, "le", 8),
    relayEventData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayEventData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayEventData.depositId),
    new BN(relayEventData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayEventData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    Buffer.from(relayEventData.messageHash), // Renamed to messageHash in the event data.
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
export class LargeAccountsCoder<A extends string = string> extends BorshAccountsCoder<A> {
  // Getter to access the private accountLayouts property from base class.
  private getAccountLayouts() {
    return (this as any).accountLayouts as Map<A, Layout>;
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

type KeyModeMap = Map<string, { isWritable: boolean }>;

// Modified version of CompiledKeys to handle compilation of unsigned transactions. Original implementation is here:
// https://github.com/solana-labs/solana-web3.js/blob/v1.95.3/src/message/compiled-keys.ts
class UnsignedCompiledKeys {
  keyModeMap: KeyModeMap;
  payer?: PublicKey;

  constructor(keyModeMap: KeyModeMap, payer?: PublicKey) {
    this.keyModeMap = keyModeMap;
    this.payer = payer;
  }

  static compileUnsigned(instructions: TransactionInstruction[], payer?: PublicKey): UnsignedCompiledKeys {
    const keyModeMap: KeyModeMap = new Map();
    const getOrInsertDefault = (pubkey: PublicKey): { isWritable: boolean } => {
      const address = pubkey.toBase58();
      let keyMode = keyModeMap.get(address);
      if (keyMode === undefined) {
        keyMode = {
          isWritable: false,
        };
        keyModeMap.set(address, keyMode);
      }
      return keyMode;
    };

    if (payer !== undefined) {
      const payerKeyMode = getOrInsertDefault(payer);
      payerKeyMode.isWritable = true;
    }

    for (const ix of instructions) {
      getOrInsertDefault(ix.programId);
      for (const accountMeta of ix.keys) {
        const keyMode = getOrInsertDefault(accountMeta.pubkey);
        keyMode.isWritable ||= accountMeta.isWritable;
      }
    }

    return new UnsignedCompiledKeys(keyModeMap, payer);
  }

  getMessageComponents(): [MessageHeader, PublicKey[]] {
    const mapEntries = [...this.keyModeMap.entries()];
    if (mapEntries.length > 256) throw new Error("Max static account keys length exceeded");

    const writableNonSigners = mapEntries.filter(([, mode]) => mode.isWritable);
    const readonlyNonSigners = mapEntries.filter(([, mode]) => !mode.isWritable);

    const header: MessageHeader = {
      numRequiredSignatures: 0,
      numReadonlySignedAccounts: 0,
      numReadonlyUnsignedAccounts: readonlyNonSigners.length,
    };

    const staticAccountKeys = [
      ...writableNonSigners.map(([address]) => new PublicKey(address)),
      ...readonlyNonSigners.map(([address]) => new PublicKey(address)),
    ];

    return [header, staticAccountKeys];
  }
}

// Extended version of legacy Message to handle compilation of unsigned transactions. Base implementation is here:
// https://github.com/solana-labs/solana-web3.js/blob/v1.95.3/src/message/legacy.ts
class UnsignedMessage extends Message {
  static compileUnsigned(instructions: TransactionInstruction[], payer?: PublicKey): Message {
    const compiledKeys = UnsignedCompiledKeys.compileUnsigned(instructions, payer);
    const [header, staticAccountKeys] = compiledKeys.getMessageComponents();
    const accountKeys = new MessageAccountKeys(staticAccountKeys);
    const compiledInstructions = accountKeys.compileInstructions(instructions).map(
      (ix: MessageCompiledInstruction): CompiledInstruction => ({
        programIdIndex: ix.programIdIndex,
        accounts: ix.accountKeyIndexes,
        data: bs58.encode(ix.data),
      })
    );
    return new Message({
      header,
      accountKeys: staticAccountKeys,
      recentBlockhash: "", // Not used as we are not signing the transaction.
      instructions: compiledInstructions,
    });
  }
}

// Helper to encode message compiled transactions for Across+ multicall handler.
export class MulticallHandlerCoder {
  readonly compiledMessage: Message;

  private readonly layout: Layout;

  constructor(instructions: TransactionInstruction[], payerKey?: PublicKey) {
    // Compile transaction message and keys.
    this.compiledMessage = UnsignedMessage.compileUnsigned(instructions, payerKey);

    // Setup the layout for the encoder.
    const fieldLayouts = [IdlCoder.fieldLayout(MulticallHandlerCoder.coderArg, MulticallHandlerCoder.coderTypes)];
    this.layout = borsh.struct(fieldLayouts);
  }

  private static coderArg = {
    name: "compiledIxs",
    type: {
      vec: {
        defined: {
          name: "compiledIx",
        },
      },
    },
  };

  private static coderTypes: IdlTypeDef[] = [
    {
      name: "compiledIx",
      type: {
        kind: "struct",
        fields: [
          {
            name: "programIdIndex",
            type: "u8",
          },
          {
            name: "accountKeyIndexes",
            type: {
              vec: "u8",
            },
          },
          {
            name: "data",
            type: "bytes",
          },
        ],
      },
    },
  ];

  get readOnlyLen() {
    return (
      this.compiledMessage.header.numReadonlySignedAccounts + this.compiledMessage.header.numReadonlyUnsignedAccounts
    );
  }

  get compiledKeyMetas() {
    return this.compiledMessage.accountKeys.map((key, index) => {
      return {
        pubkey: key,
        isSigner: this.compiledMessage.isAccountSigner(index),
        isWritable: this.compiledMessage.isAccountWritable(index),
      };
    });
  }

  encode() {
    const buffer = Buffer.alloc(1280);
    const len = this.layout.encode({ compiledIxs: this.compiledMessage.compiledInstructions }, buffer);
    return buffer.slice(0, len);
  }
}

type AcrossPlusMessage = {
  handler: PublicKey;
  readOnlyLen: number;
  valueAmount: BN;
  accounts: PublicKey[];
  handlerMessage: Buffer;
};

export class AcrossPlusMessageCoder {
  private acrossPlusMessage: AcrossPlusMessage;

  constructor(acrossPlusMessage: AcrossPlusMessage) {
    this.acrossPlusMessage = acrossPlusMessage;
  }

  private static coderArg = {
    name: "message",
    type: {
      defined: {
        name: "acrossPlusMessage",
      },
    },
  };

  private static coderTypes: IdlTypeDef[] = [
    {
      name: "acrossPlusMessage",
      type: {
        kind: "struct",
        fields: [
          {
            name: "handler",
            type: "pubkey",
          },
          {
            name: "readOnlyLen",
            type: "u8",
          },
          {
            name: "valueAmount",
            type: "u64",
          },
          {
            name: "accounts",
            type: {
              vec: "pubkey",
            },
          },
          {
            name: "handlerMessage",
            type: "bytes",
          },
        ],
      },
    },
  ];

  encode() {
    const fieldLayouts = [IdlCoder.fieldLayout(AcrossPlusMessageCoder.coderArg, AcrossPlusMessageCoder.coderTypes)];
    const layout = borsh.struct(fieldLayouts);
    const buffer = Buffer.alloc(12800);
    const len = layout.encode({ message: this.acrossPlusMessage }, buffer);
    return buffer.slice(0, len);
  }
}

// Helper to send instructions using Address Lookup Table (ALT) for large number of accounts.
export async function sendTransactionWithLookupTable(
  connection: Connection,
  instructions: TransactionInstruction[],
  sender: Keypair
): Promise<{ txSignature: string; lookupTableAddress: PublicKey }> {
  // Maximum number of accounts that can be added to Address Lookup Table (ALT) in a single transaction.
  const maxExtendedAccounts = 30;

  // Consolidate addresses from all instructions into a single array for the ALT.
  const lookupAddresses = Array.from(
    new Set(
      instructions.flatMap((instruction) => [
        instruction.programId,
        ...instruction.keys.map((accountMeta) => accountMeta.pubkey),
      ])
    )
  );

  // Create instructions for creating and extending the ALT.
  const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
    authority: sender.publicKey,
    payer: sender.publicKey,
    recentSlot: await connection.getSlot(),
  });

  // Submit the ALT creation transaction
  await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(lookupTableInstruction), [sender], {
    skipPreflight: true, // Avoids recent slot mismatch in simulation.
  });

  // Extend the ALT with all accounts making sure not to exceed the maximum number of accounts per transaction.
  for (let i = 0; i < lookupAddresses.length; i += maxExtendedAccounts) {
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: sender.publicKey,
      payer: sender.publicKey,
      addresses: lookupAddresses.slice(i, i + maxExtendedAccounts),
    });

    await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(extendInstruction), [sender], {
      skipPreflight: true, // Avoids recent slot mismatch in simulation.
    });
  }

  // Avoids invalid ALT index as ALT might not be active yet on the following tx.
  await new Promise((resolve) => setTimeout(resolve, 1000));

  // Fetch the AddressLookupTableAccount
  const lookupTableAccount = (await connection.getAddressLookupTable(lookupTableAddress)).value;
  if (lookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");

  // Create the versioned transaction
  const versionedTx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: sender.publicKey,
      recentBlockhash: (await connection.getLatestBlockhash()).blockhash,
      instructions,
    }).compileToV0Message([lookupTableAccount])
  );

  // Sign and submit the versioned transaction.
  versionedTx.sign([sender]);
  const txSignature = await connection.sendTransaction(versionedTx);

  return { txSignature, lookupTableAddress };
}

export function hashNonEmptyMessage(message: Buffer) {
  if (message.length > 0) {
    const hash = ethers.utils.keccak256(message);
    return Uint8Array.from(Buffer.from(hash.slice(2), "hex"));
  }
  // else return zeroed bytes32
  return new Uint8Array(32);
}
