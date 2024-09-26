use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct InstructionData {
    #[max_len(0)]
    pub data: Vec<u8>,
}
