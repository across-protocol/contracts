import {
  AddressesByLookupTableAddress,
  appendTransactionMessageInstructions,
  compressTransactionMessageUsingAddressLookupTables as compressTxWithAlt,
  getSignatureFromTransaction,
  IInstruction,
  KeyPairSigner,
  pipe,
  sendAndConfirmTransactionFactory,
  signTransactionMessageWithSigners,
} from "@solana/kit";

import { createDefaultTransaction } from "../../../test/svm/utils";

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
