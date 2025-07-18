import {
  Address,
  AddressesByLookupTableAddress,
  appendTransactionMessageInstruction,
  appendTransactionMessageInstructions,
  Commitment,
  CompilableTransactionMessage,
  compressTransactionMessageUsingAddressLookupTables as compressTxWithAlt,
  createTransactionMessage,
  getSignatureFromTransaction,
  IInstruction,
  KeyPairSigner,
  pipe,
  sendAndConfirmTransactionFactory,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
  TransactionMessageWithBlockhashLifetime,
  TransactionSigner,
} from "@solana/kit";

import {
  fetchAddressLookupTable,
  findAddressLookupTablePda,
  getCreateLookupTableInstructionAsync,
  getExtendLookupTableInstruction,
} from "@solana-program/address-lookup-table";
import { RpcClient } from "./types";

/**
 * Signs and sends a transaction.
 */
export const signAndSendTransaction = async (
  rpcClient: RpcClient,
  transactionMessage: CompilableTransactionMessage & TransactionMessageWithBlockhashLifetime,
  commitment: Commitment = "confirmed"
) => {
  const signedTransaction = await signTransactionMessageWithSigners(transactionMessage);
  const signature = getSignatureFromTransaction(signedTransaction);
  await sendAndConfirmTransactionFactory(rpcClient)(signedTransaction, {
    commitment,
  });
  return signature;
};

export const createDefaultTransaction = async (rpcClient: RpcClient, signer: TransactionSigner) => {
  const { value: latestBlockhash } = await rpcClient.rpc.getLatestBlockhash().send();
  return pipe(
    createTransactionMessage({ version: 0 }),
    (tx) => setTransactionMessageFeePayerSigner(signer, tx),
    (tx) => setTransactionMessageLifetimeUsingBlockhash(latestBlockhash, tx)
  );
};

/**
 * Sends a transaction with an Address Lookup Table.
 */
export async function sendTransactionWithLookupTable(
  client: RpcClient,
  payer: KeyPairSigner,
  instructions: IInstruction[],
  addressesByLookupTableAddress: AddressesByLookupTableAddress
) {
  return pipe(
    await createDefaultTransaction(client, payer),
    (tx) => appendTransactionMessageInstructions(instructions, tx),
    (tx) => compressTxWithAlt(tx, addressesByLookupTableAddress),
    (tx) => signTransactionMessageWithSigners(tx),
    async (tx) => {
      const signedTx = await tx;
      await sendAndConfirmTransactionFactory(client)(signedTx, {
        commitment: "confirmed",
        skipPreflight: false,
      });
      return getSignatureFromTransaction(signedTx);
    }
  );
}

/**
 * Creates an Address Lookup Table.
 */
export async function createLookupTable(client: RpcClient, authority: KeyPairSigner): Promise<Address> {
  const recentSlot = await client.rpc.getSlot({ commitment: "finalized" }).send();

  const [alt] = await findAddressLookupTablePda({
    authority: authority.address,
    recentSlot,
  });

  const createAltIx = await getCreateLookupTableInstructionAsync({
    authority,
    recentSlot,
  });

  await pipe(
    await createDefaultTransaction(client, authority),
    (tx) => appendTransactionMessageInstruction(createAltIx, tx),
    (tx) => signAndSendTransaction(client, tx)
  );

  return alt;
}

/**
 * Extends an Address Lookup Table.
 */
export async function extendLookupTable(
  client: RpcClient,
  authority: KeyPairSigner,
  alt: Address,
  addresses: Address[]
) {
  const extendAltIx = getExtendLookupTableInstruction({
    address: alt,
    authority,
    payer: authority,
    addresses,
  });

  await pipe(
    await createDefaultTransaction(client, authority),
    (tx) => appendTransactionMessageInstruction(extendAltIx, tx),
    (tx) => signAndSendTransaction(client, tx)
  );

  const altAccount = await fetchAddressLookupTable(client.rpc, alt);

  const addressesByLookupTableAddress: AddressesByLookupTableAddress = {};
  addressesByLookupTableAddress[alt] = altAccount.data.addresses;

  // Delay a second here to let lookup table warm up
  await new Promise((resolve) => setTimeout(resolve, 1000));

  return addressesByLookupTableAddress;
}
