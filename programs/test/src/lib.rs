use anchor_lang::prelude::*;
use svm_spoke::{ constants::DISCRIMINATOR_SIZE, error::SharedError, utils::{ is_claimed, process_proof, set_claimed } };

declare_id!("84j1xFuoz2xynhesB8hxC5N1zaWPr4MW1DD2gVm9PUs4");

// This program is used to test the svm_spoke program internal utils methods. It's kept separate from the svm_spoke
// as it simply exports utils methods so direct unit tests can be run against them.

#[program]
pub mod test {
    use super::*;

    // Test Bitmap.
    #[derive(Accounts)]
    pub struct InitializeBitmap<'info> {
        #[account(
            init,
            payer = signer,
            space = DISCRIMINATOR_SIZE + BitmapAccount::INIT_SPACE,
            seeds = [b"bitmap_account"],
            bump
        )]
        pub bitmap_account: Account<'info, BitmapAccount>,
        #[account(mut)]
        pub signer: Signer<'info>,
        pub system_program: Program<'info, System>,
    }

    pub fn initialize(ctx: Context<InitializeBitmap>) -> Result<()> {
        let bitmap_account = &mut ctx.accounts.bitmap_account;
        bitmap_account.claimed_bitmap = vec![]; // Initialize Vec with zero size
        Ok(())
    }

    #[derive(Accounts)]
    #[instruction(index: u32)]
    pub struct UpdateBitmap<'info> {
        #[account(mut,
        realloc = DISCRIMINATOR_SIZE + BitmapAccount::INIT_SPACE + index as usize / 8,
        realloc::payer = signer,
        realloc::zero = false)]
        pub bitmap_account: Account<'info, BitmapAccount>,

        #[account(mut)]
        pub signer: Signer<'info>,

        pub system_program: Program<'info, System>,
    }

    pub fn test_set_claimed(ctx: Context<UpdateBitmap>, index: u32) -> Result<()> {
        let bitmap_account = &mut ctx.accounts.bitmap_account; // Change to mutable reference
        set_claimed(&mut bitmap_account.claimed_bitmap, index);
        Ok(())
    }

    #[derive(Accounts)]
    pub struct ViewBitmap<'info> {
        pub bitmap_account: Account<'info, BitmapAccount>,
    }
    pub fn test_is_claimed(ctx: Context<ViewBitmap>, index: u32) -> Result<bool> {
        let bitmap_account = &ctx.accounts.bitmap_account;
        let result = is_claimed(&bitmap_account.claimed_bitmap, index);
        Ok(result)
    }

    // Test Merkle.
    #[derive(Accounts)]
    pub struct Verify {}
    pub fn verify(ctx: Context<Verify>, root: [u8; 32], leaf: [u8; 32], proof: Vec<[u8; 32]>) -> Result<()> {
        let computed_root = process_proof(&proof, &leaf);
        if computed_root != root {
            return err!(SharedError::InvalidMerkleProof);
        }

        Ok(())
    }

    #[derive(Accounts)]
    pub struct EmitLargeLog {}
    #[event]
    pub struct TestEvent {
        message: String,
    }
    pub fn test_emit_large_log(_ctx: Context<EmitLargeLog>, length: u32) -> Result<()> {
        let large_message = "LOG_TO_TEST_LARGE_MESSAGE".repeat(length as usize);
        emit!(TestEvent {
            message: large_message.into(),
        });
        Ok(())
    }
}

// State.

#[derive(InitSpace)]
#[account]
pub struct BitmapAccount {
    #[max_len(1)]
    pub claimed_bitmap: Vec<u8>,
}
