use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct Route {
    pub enabled: bool, // Tracks if the route is enabled.
}
