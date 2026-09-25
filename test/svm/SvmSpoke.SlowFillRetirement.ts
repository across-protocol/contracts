import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import { createMint, getAccount, getOrCreateAssociatedTokenAccount, mintTo } from "@solana/spl-token";
import { PublicKey, Transaction, TransactionInstruction } from "@solana/web3.js";
import { assert } from "chai";
import { SvmSpokeClient } from "../../src/svm/clients";
import { calculateRelayHashUint8Array } from "../../src/svm/web3-v1";
import { SvmSpokeIdl } from "../../src/svm/assets";
import legacyAccount from "./accounts/legacy_requested_slow_fill.json";
import { legacyMint, legacyRelay, legacyRequester } from "./fixtures/legacySlowFill";
import { common } from "./SvmSpoke.common";

describe("svm_spoke V4 and slow-fill retirement compatibility", () => {
  const { provider, connection, program, chainId } = common;
  anchor.setProvider(provider);
  const payer = (provider.wallet as anchor.Wallet).payer;
  const fillStatus = new PublicKey(legacyAccount.pubkey);
  const relayHash = calculateRelayHashUint8Array(legacyRelay, chainId);
  let state: PublicKey, recipient: PublicKey, vault: PublicKey;

  before(async () => {
    ({ state } = await common.initializeState());
    await createMint(connection, payer, payer.publicKey, null, 6, legacyMint);
    recipient = (
      await getOrCreateAssociatedTokenAccount(connection, payer, legacyMint.publicKey, legacyRelay.recipient)
    ).address;
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, legacyMint.publicKey, state, true)).address;
    await mintTo(connection, payer, legacyMint.publicKey, vault, payer, 1000000);
    assert.equal(
      PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId)[0].toBase58(),
      fillStatus.toBase58()
    );
  });

  it("removes client entrypoints while retaining historical event decoding", () => {
    for (const name of ["Deposit", "DepositNow", "UnsafeDeposit", "FillRelay", "GetUnsafeDepositId"]) {
      assert.notProperty(SvmSpokeClient, `get${name}Instruction`);
      assert.notProperty(SvmSpokeClient, `get${name}InstructionAsync`);
    }
    assert.property(SvmSpokeClient, "getAdapterExecuteAcrossV5Instruction");
    for (const suffix of ["Encoder", "Decoder", "Codec"]) {
      assert.notProperty(SvmSpokeClient, `getFillRelayParams${suffix}`);
      assert.property(SvmSpokeClient, `getRelayData${suffix}`);
      assert.property(SvmSpokeClient, `getV5FillJit${suffix}`);
    }
    for (const idl of [program.idl, SvmSpokeIdl]) {
      const names = idl.instructions.map((ix: { name: string }) => ix.name.replace(/_/g, "").toLowerCase());
      for (const name of ["deposit", "depositnow", "unsafedeposit", "fillrelay", "getunsafedepositid"])
        assert.notInclude(names, name);
      assert.include(names, "adapterexecuteacrossv5");
      assert.include(names, "executerelayerrefundleaf");
      assert.include(names, "closefillpda");
      assert.notInclude(names, "requestslowfill");
      assert.notInclude(names, "executeslowrelayleaf");
      const typeNames = idl.types.map((type: { name: string }) => type.name.replace(/_/g, "").toLowerCase());
      const accountNames = idl.accounts.map((account: { name: string }) =>
        account.name.replace(/_/g, "").toLowerCase()
      );
      assert.notInclude(accountNames, "fillrelayparams");
      assert.notInclude(typeNames, "fillrelayparams");
      assert.include(typeNames, "relaydata");
      assert.include(typeNames, "v5filljit");
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

  it("rejects all retired raw selectors before account validation, with no state or token changes", async () => {
    const before = (await connection.getAccountInfo(fillStatus))!;
    for (const discriminator of [
      [242, 35, 198, 137, 82, 225, 242, 182], // deposit
      [75, 228, 135, 221, 200, 25, 148, 26], // deposit_now
      [196, 187, 166, 179, 3, 146, 150, 246], // unsafe_deposit
      [100, 84, 222, 90, 106, 209, 58, 222], // fill_relay
      [118, 10, 135, 0, 168, 243, 223, 117], // get_unsafe_deposit_id
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

  it("retains historical requested status and permissionless expiry reclaim to the recorded requester", async () => {
    const before = (await connection.getAccountInfo(fillStatus))!;
    assert.deepEqual(before.data, Buffer.from(legacyAccount.account.data[0], "base64"));
    const requested = await program.account.fillStatusAccount.fetch(fillStatus);
    assert.deepEqual(requested.status, { requestedSlowFill: {} });
    assert.equal(requested.relayer.toBase58(), legacyRequester.toBase58());

    await common.setCurrentTime(program, state, payer, new BN(legacyRelay.fillDeadline));
    try {
      await program.methods.closeFillPda().accountsPartial({ state, signer: legacyRequester, fillStatus }).rpc();
      assert.fail("Must wait until after the recorded deadline");
    } catch (error: any) {
      assert.include(error.toString(), "CanOnlyCloseFillStatusPdaIfFillDeadlinePassed");
    }
    assert.deepEqual((await connection.getAccountInfo(fillStatus))!.data, before.data);

    await common.setCurrentTime(program, state, payer, new BN(legacyRelay.fillDeadline + 1));
    const rentBefore = await connection.getBalance(legacyRequester);
    // The provider pays transaction fees; the recorded requester need not sign.
    await program.methods.closeFillPda().accountsPartial({ state, signer: legacyRequester, fillStatus }).rpc();
    assert.isNull(await connection.getAccountInfo(fillStatus));
    assert.equal(await connection.getBalance(legacyRequester), rentBefore + before.lamports);
    assert.equal((await getAccount(connection, vault)).amount, 1000000n);
    assert.equal((await getAccount(connection, recipient)).amount, 0n);
  });
});
