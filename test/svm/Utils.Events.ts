import * as anchor from "@coral-xyz/anchor";
import { BorshCoder, EventParser, Program } from "@coral-xyz/anchor";
import { expect } from "chai";
import { Test } from "../../target/types/test";
import { ParsedInstruction } from "@solana/web3.js";

describe("utils.events", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.Test as Program<Test>;

  const createLargeLog = async (size: number) => {
    const connection = program.provider.connection;

    const tx = await program.methods.testEmitLargeLog(size).accounts({}).rpc();

    const latestBlockHash = await connection.getLatestBlockhash();
    await connection.confirmTransaction(
      {
        blockhash: latestBlockHash.blockhash,
        lastValidBlockHeight: latestBlockHash.lastValidBlockHeight,
        signature: tx,
      },
      "confirmed"
    );

    const txDetails = await program.provider.connection.getTransaction(tx, {
      maxSupportedTransactionVersion: 0,
      commitment: "confirmed",
    });

    const logs = txDetails?.meta?.logMessages || null;

    if (!logs) {
      throw new Error("No logs found");
    }

    return logs;
  };

  const parseLogs = async (logs: string[]) => {
    const eventParser = new EventParser(program.programId, new BorshCoder(program.idl));
    const events = eventParser.parseLogs(logs);

    const returnEvents: any[] = [];
    for (let event of events) {
      returnEvents.push(event);
    }

    return returnEvents;
  };

  it("Large events are truncated", async () => {
    let size = 100;
    const logMessage = "LOG_TO_TEST_LARGE_MESSAGE";

    const logs = await createLargeLog(size);
    const parsedLogs = await parseLogs(logs);

    expect(parsedLogs.length).to.equal(1);
    expect(parsedLogs[0].data.message).to.include(`${logMessage.repeat(size)}`);

    size = 500;
    const truncatedLogs = await createLargeLog(size);
    const parsedTruncatedLogs = await parseLogs(truncatedLogs);

    expect(parsedTruncatedLogs.length).to.equal(0);
    expect(truncatedLogs).to.include("Log truncated");

    // Find transactions with truncated logs and recover function call and arguments
    const connection = program.provider.connection;
    const pastSignatures = await connection.getSignaturesForAddress(
      program.programId,
      {
        limit: 1000,
      },
      "confirmed"
    );

    let recoveredFunctionName;
    let recoveredLength;

    for (let signature of pastSignatures) {
      const txResult = await connection.getParsedTransaction(signature.signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });

      if (!txResult) {
        continue;
      }

      // skip if logs have not been truncated
      if (!txResult?.meta?.logMessages?.includes("Log truncated")) {
        continue;
      }

      const borshCoder = new BorshCoder(program.idl);
      const instruction = txResult?.transaction.message.instructions[0];
      if (!instruction) {
        continue;
      }
      let decodedIx;
      if ("data" in instruction) {
        decodedIx = borshCoder.instruction.decode(instruction.data, "base58");
        recoveredFunctionName = decodedIx?.name;
      } else {
        console.error("Instruction does not have data");
      }

      recoveredFunctionName = decodedIx?.name;
      recoveredLength = (decodedIx as unknown as { data: { length: number } }).data.length;
    }

    expect(recoveredFunctionName).to.equal("testEmitLargeLog");
    expect(recoveredLength).to.equal(size);
  });
});
