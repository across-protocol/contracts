use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub seed: u64, // Seed used when running tests to avoid address collisions. 0 on mainnet.
                   // TODO: Add other required fields, e.g. the program owner and authorized quote signer(-s).
}
