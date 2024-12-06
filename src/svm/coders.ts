import { BorshAccountsCoder } from "@coral-xyz/anchor";
import { IdlCoder } from "@coral-xyz/anchor/dist/cjs/coder/borsh/idl";
import { IdlTypeDef } from "@coral-xyz/anchor/dist/cjs/idl";
import * as borsh from "@coral-xyz/borsh";
import {
  CompiledInstruction,
  Message,
  MessageAccountKeys,
  MessageCompiledInstruction,
  MessageHeader,
  PublicKey,
  TransactionInstruction,
} from "@solana/web3.js";
import bs58 from "bs58";
import { Layout } from "buffer-layout";
import { AcrossPlusMessage } from "../types/svm";

/**
 * Extended Anchor accounts coder to handle large account data.
 */
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

/**
 * Extended version of legacy CompiledKeys to handle compilation of unsigned transactions. Base implementation is here:
 * https://github.com/solana-labs/solana-web3.js/blob/v1.95.3/src/message/compiled-keys.ts
 */
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

/**
 * Extended version of legacy Message to handle compilation of unsigned transactions. Base implementation is here:
 * https://github.com/solana-labs/solana-web3.js/blob/v1.95.3/src/message/legacy.ts
 */
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

/**
 * Helper to encode MulticallHandler transactions.
 */
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

/**
 * Helper to encode Across+ messages.
 */
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
