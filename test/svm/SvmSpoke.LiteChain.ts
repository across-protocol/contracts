import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  createApproveCheckedInstruction,
  createMint,
  getAccount,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction } from "@solana/web3.js";
import { assert } from "chai";
import { calculateRelayHashUint8Array, getFillRelayDelegatePda, readEventsUntilFound } from "../../src/svm/web3-v1";
import { SvmSpokeIdl } from "../../src/svm/assets";
import legacyAccount from "./accounts/legacy_requested_slow_fill.json";
import { legacyMint, legacyRelay, legacyRequester } from "./fixtures/legacySlowFill";
import { common } from "./SvmSpoke.common";

describe("svm_spoke lite-chain compatibility", () => {
  const { provider, connection, program, chainId } = common;
  anchor.setProvider(provider);
  const payer = (provider.wallet as anchor.Wallet).payer;
  const relayer = Keypair.generate();
  const fillStatus = new PublicKey(legacyAccount.pubkey);
  const relayHash = calculateRelayHashUint8Array(legacyRelay, chainId);
  let state: PublicKey, source: PublicKey, recipient: PublicKey, vault: PublicKey;

  before(async () => {
    ({ state } = await common.initializeState());
    await provider.sendAndConfirm(
      new Transaction().add(
        SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: relayer.publicKey, lamports: 100000000 })
      )
    );
    await createMint(connection, payer, payer.publicKey, null, 6, legacyMint);
    source = (await getOrCreateAssociatedTokenAccount(connection, payer, legacyMint.publicKey, relayer.publicKey))
      .address;
    recipient = (
      await getOrCreateAssociatedTokenAccount(connection, payer, legacyMint.publicKey, legacyRelay.recipient)
    ).address;
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, legacyMint.publicKey, state, true)).address;
    await mintTo(connection, payer, legacyMint.publicKey, source, payer, 1000000);
    await mintTo(connection, payer, legacyMint.publicKey, vault, payer, 1000000);
    assert.equal(
      PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId)[0].toBase58(),
      fillStatus.toBase58()
    );
  });

  it("removes client entrypoints while retaining historical event decoding", () => {
    for (const idl of [program.idl, SvmSpokeIdl]) {
      const names = idl.instructions.map((ix: { name: string }) => ix.name.replace(/_/g, "").toLowerCase());
      assert.notInclude(names, "requestslowfill");
      assert.notInclude(names, "executeslowrelayleaf");
      const coder = new anchor.BorshCoder(new anchor.Program(idl, provider).idl);
      const request = Buffer.concat([Buffer.from([221, 123, 11, 14, 71, 37, 178, 167]), Buffer.alloc(280)]);
      assert.equal(coder.events.decode(request.toString("base64"))?.name, "requestedSlowFill");
      for (const [slot, name] of ["fastFill", "replacedSlowFill", "slowFill"].entries()) {
        const event = Buffer.concat([
          Buffer.from([25, 58, 182, 0, 50, 99, 160, 117]),
          Buffer.alloc(392),
          Buffer.from([slot]),
        ]);
        assert.deepEqual(coder.events.decode(event.toString("base64"))?.data.relayExecutionInfo.fillType, {
          [name]: {},
        });
      }
    }
  });

  it("rejects both retired raw selectors before account validation, with no state or token changes", async () => {
    const before = (await connection.getAccountInfo(fillStatus))!;
    for (const discriminator of [
      [39, 157, 165, 187, 88, 217, 207, 98],
      [26, 207, 3, 168, 193, 252, 59, 127],
    ]) {
      for (const payload of [Buffer.alloc(0), Buffer.alloc(512)]) {
        const ix = new TransactionInstruction({
          programId: program.programId,
          keys: [fillStatus, vault, recipient].map((pubkey) => ({ pubkey, isSigner: false, isWritable: true })),
          data: Buffer.concat([Buffer.from(discriminator), payload]),
        });
        try {
          await provider.sendAndConfirm(new Transaction().add(ix));
          assert.fail("Removed selector must fail");
        } catch (error: any) {
          assert.include(error.toString(), "custom program error: 0x65"); // InstructionFallbackNotFound (101).
        }
      }
    }
    assert.deepEqual((await connection.getAccountInfo(fillStatus))!.data, before.data);
    assert.equal((await getAccount(connection, vault)).amount, 1000000n);
    assert.equal((await getAccount(connection, recipient)).amount, 0n);
  });

  const fillTransaction = async () => {
    const { pda: delegate } = getFillRelayDelegatePda(relayHash, chainId, relayer.publicKey, program.programId);
    return new Transaction().add(
      createApproveCheckedInstruction(source, legacyMint.publicKey, delegate, relayer.publicKey, 500000, 6),
      await program.methods
        .fillRelay([...relayHash], legacyRelay, chainId, relayer.publicKey)
        .accountsPartial({
          signer: relayer.publicKey,
          instructionParams: null,
          state,
          delegate,
          mint: legacyMint.publicKey,
          relayerTokenAccount: source,
          recipientTokenAccount: recipient,
          fillStatus,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .instruction()
    );
  };

  it("rolls back a fast fill of a pre-upgrade request, then fills once with ReplacedSlowFill", async () => {
    const before = (await connection.getAccountInfo(fillStatus))!;
    assert.equal(before.data[8], 1);
    assert.deepEqual(before.data, Buffer.from(legacyAccount.account.data[0], "base64"));
    const requested = await program.account.fillStatusAccount.fetch(fillStatus);
    assert.deepEqual(requested.status, { requestedSlowFill: {} });
    assert.equal(requested.relayer.toBase58(), legacyRequester.toBase58());

    // Submit an actual failed transaction: fill succeeds, then an impossible SOL transfer forces rollback.
    const tx = (await fillTransaction()).add(
      SystemProgram.transfer({
        fromPubkey: relayer.publicKey,
        toPubkey: payer.publicKey,
        lamports: 100000000000,
      })
    );
    const blockhash = await connection.getLatestBlockhash();
    tx.recentBlockhash = blockhash.blockhash;
    tx.feePayer = payer.publicKey;
    tx.sign(payer, relayer);
    const signature = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: true });
    const failed = await connection.confirmTransaction({ signature, ...blockhash }, "confirmed");
    assert.deepEqual((failed.value.err as any)?.InstructionError?.[0], 2);
    assert.deepEqual((await connection.getAccountInfo(fillStatus))!.data, before.data);
    assert.equal((await getAccount(connection, source)).amount, 1000000n);
    assert.equal((await getAccount(connection, recipient)).amount, 0n);

    const successful = await provider.sendAndConfirm(await fillTransaction(), [relayer]);
    const events = await readEventsUntilFound(connection, successful, [program]);
    const event = events.find((event) => event.name === "filledRelay")?.data;
    assert.deepEqual(event.relayExecutionInfo.fillType, { replacedSlowFill: {} });
    assert.equal(event.relayExecutionInfo.updatedOutputAmount.toString(), "500000");
    const filled = await program.account.fillStatusAccount.fetch(fillStatus);
    assert.deepEqual(filled.status, { filled: {} });
    assert.equal(filled.relayer.toBase58(), relayer.publicKey.toBase58());
    assert.equal(filled.fillDeadline, legacyRelay.fillDeadline);
    assert.equal((await connection.getAccountInfo(fillStatus))!.data[8], 2);
    assert.equal((await getAccount(connection, source)).amount, 500000n);
    assert.equal((await getAccount(connection, recipient)).amount, 500000n);
    assert.equal((await getAccount(connection, vault)).amount, 1000000n);

    try {
      await provider.sendAndConfirm(await fillTransaction(), [relayer]);
      assert.fail("Replay must fail");
    } catch (error: any) {
      assert.include(error.toString(), "RelayFilled");
    }
    assert.equal((await getAccount(connection, recipient)).amount, 500000n);

    // The successful fast filler becomes the rent recipient; ordinary expiry reclaim remains available.
    await common.setCurrentTime(program, state, payer, new BN(legacyRelay.fillDeadline + 1));
    await program.methods.closeFillPda().accountsPartial({ state, signer: relayer.publicKey, fillStatus }).rpc();
    assert.isNull(await connection.getAccountInfo(fillStatus));
  });
});
