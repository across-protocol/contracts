import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Test } from "../../target/types/test";
import { assert } from "chai";
import { SystemProgram } from "@solana/web3.js";

describe("utils.bitmap", () => {
  anchor.setProvider(anchor.AnchorProvider.env());

  const program = anchor.workspace.Test as Program<Test>;
  const provider = anchor.AnchorProvider.env();

  let bitmapAccount;
  const signer = provider.wallet.payer; // Use the provider's signer

  before(async () => {
    const seeds = [Buffer.from("bitmap_account")];
    bitmapAccount = anchor.web3.PublicKey.findProgramAddressSync(seeds, program.programId)[0];

    // Initialize the Bitmap account
    await program.methods
      .initialize()
      .accounts({
        bitmapAccount,
        signer: signer.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([signer])
      .rpc();
  });
  it("Set and read multiple claims", async () => {
    const indices = [0, 1, 42, 69, 1449, 1501];

    for (const index of indices) {
      let isClaimed = await program.methods
        .testIsClaimed(index)
        .accounts({
          bitmapAccount,
        })
        .view();
      assert.strictEqual(isClaimed, false, `Index ${index} should not be claimed initially`);
    }

    for (const index of indices) {
      await program.methods
        .testSetClaimed(index)
        .accounts({
          bitmapAccount,
          signer: signer.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([signer])
        .rpc();
    }

    for (const index of indices) {
      let isClaimed = await program.methods
        .testIsClaimed(index)
        .accounts({
          bitmapAccount,
        })
        .view();
      assert.strictEqual(isClaimed, true, `Index ${index} should be claimed after setting`);
    }

    // Checking all other indices to ensure they are not claimed.
    for (let i = 0; i <= Math.max(...indices); i++) {
      if (!indices.includes(i)) {
        let isClaimed = await program.methods
          .testIsClaimed(i)
          .accounts({
            bitmapAccount,
          })
          .view();
        assert.strictEqual(isClaimed, false, `Index ${i} should not be claimed`);
      }
    }
  });
});
