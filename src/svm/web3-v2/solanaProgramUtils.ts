import { BorshEventCoder, Idl, utils } from "@coral-xyz/anchor";
import web3, {
  Address,
  Commitment,
  GetTransactionApi,
  Signature,
  Slot,
  TransactionError,
  UnixTimestamp,
} from "@solana/web3-v2.js";

type GetTransactionReturnType = ReturnType<GetTransactionApi["getTransaction"]>;

type GetSignaturesForAddressConfig = Readonly<{
  before?: Signature;
  commitment?: Exclude<Commitment, "processed">;
  limit?: number;
  minContextSlot?: Slot;
  until?: Signature;
}>;

type GetSignaturesForAddressTransaction = {
  blockTime: UnixTimestamp | null;
  confirmationStatus: Commitment | null;
  err: TransactionError | null;
  memo: string | null;
  signature: Signature;
  slot: Slot;
};

/**
 * Reads all events for a specific program.
 */
export async function readProgramEvents(
  rpc: web3.Rpc<web3.SolanaRpcApiFromTransport<any>>,
  program: Address,
  anchorIdl: Idl,
  finality: Commitment = "confirmed",
  options: GetSignaturesForAddressConfig = { limit: 1000 }
) {
  const allSignatures: GetSignaturesForAddressTransaction[] = [];

  // Fetch all signatures in sequential batches
  while (true) {
    const signatures = await rpc.getSignaturesForAddress(program, options).send();
    allSignatures.push(...signatures);

    // Update options for the next batch. Set before to the last fetched signature.
    if (signatures.length > 0) {
      options = { ...options, before: signatures[signatures.length - 1].signature };
    }

    if (options.limit && signatures.length < options.limit) break; // Exit early if the number of signatures < limit
  }

  // Fetch events for all signatures in parallel
  const eventsWithSlots = await Promise.all(
    allSignatures.map(async (signatureTransaction) => {
      const events = await readEvents(rpc, signatureTransaction.signature, program, anchorIdl, finality);

      return events.map((event) => ({
        ...event,
        confirmationStatus: signatureTransaction.confirmationStatus || "Unknown",
        blockTime: signatureTransaction.blockTime || 0,
        signature: signatureTransaction.signature,
        slot: signatureTransaction.slot,
        name: event.name || "Unknown",
      }));
    })
  );
  return eventsWithSlots.flat();
}

/**
 * Reads events from a transaction.
 */
export async function readEvents(
  rpc: web3.Rpc<web3.SolanaRpcApiFromTransport<any>>,
  txSignature: Signature,
  programId: Address,
  programIdl: Idl,
  commitment: Commitment = "confirmed"
) {
  const txResult = await rpc.getTransaction(txSignature, { commitment, maxSupportedTransactionVersion: 0 }).send();

  if (txResult === null) return [];

  return processEventFromTx(txResult, programId, programIdl);
}

/**
 * Processes events from a transaction.
 */
async function processEventFromTx(
  txResult: GetTransactionReturnType,
  programId: Address,
  programIdl: Idl
): Promise<{ program: Address; data: any; name: string | undefined }[]> {
  if (!txResult) return [];
  const eventAuthorities: Map<string, Address> = new Map();
  const events: { program: Address; data: any; name: string | undefined }[] = [];
  const [pda] = await web3.getProgramDerivedAddress({ programAddress: programId, seeds: ["__event_authority"] });
  eventAuthorities.set(programId, pda);

  const messageAccountKeys = txResult.transaction.message.accountKeys;

  for (const ixBlock of txResult.meta?.innerInstructions ?? []) {
    for (const ix of ixBlock.instructions) {
      const ixProgramId = messageAccountKeys[ix.programIdIndex];
      const singleIxAccount = ix.accounts.length === 1 ? messageAccountKeys[ix.accounts[0]] : undefined;
      if (
        ixProgramId !== undefined &&
        singleIxAccount !== undefined &&
        programId == ixProgramId &&
        eventAuthorities.get(ixProgramId.toString()) == singleIxAccount
      ) {
        const ixData = utils.bytes.bs58.decode(ix.data);
        const eventData = utils.bytes.base64.encode(Buffer.from(new Uint8Array(ixData).slice(8)));
        let event = new BorshEventCoder(programIdl).decode(eventData);
        events.push({
          program: programId,
          data: event?.data,
          name: event?.name,
        });
      }
    }
  }

  return events;
}
