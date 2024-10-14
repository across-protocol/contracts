use anchor_lang::prelude::*;

use crate::error::CustomError;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub paused_deposits: bool,
    pub paused_fills: bool,
    pub owner: Pubkey,
    pub seed: u64, // Add a seed to the state to enable multiple deployments.
    pub number_of_deposits: u32,
    pub chain_id: u64,              // Across definition of chainId for Solana.
    pub current_time: u32,          // Only used in testable mode, else set to 0 on mainnet.
    pub remote_domain: u32,         // CCTP domain for Mainnet Ethereum.
    pub cross_domain_admin: Pubkey, // HubPool on Mainnet Ethereum.
    pub root_bundle_id: u32,
    pub deposit_quote_time_buffer: u32, // Deposit quote times can't be set more than this amount into the past/future.
    pub fill_deadline_buffer: u32, // Fill deadlines can't be set more than this amount into the future.
}

impl State {
    pub fn initialize_current_time(&mut self) -> Result<()> {
        #[cfg(feature = "test")]
        {
            self.current_time = Clock::get()?.unix_timestamp as u32;
        }

        Ok(())
    }

    pub fn set_current_time(&mut self, new_time: u32) -> Result<()> {
        #[cfg(not(feature = "test"))]
        {
            let _ = new_time; // Suppress warning about `new_time` being unused in non-test builds.
            return err!(CustomError::CannotSetCurrentTime);
        }

        #[cfg(feature = "test")]
        {
            self.current_time = new_time;
            Ok(())
        }
    }

    pub fn get_current_time(&self) -> Result<u32> {
        #[cfg(not(feature = "test"))]
        {
            Ok(Clock::get()?.unix_timestamp as u32)
        }

        #[cfg(feature = "test")]
        {
            Ok(self.current_time)
        }
    }
}
