//! Wire, cryptographic, account-validation, and fill-status foundations for the Gateway-facing V5 adapter.
//!
//! `V5` identifies the Across protocol generation, while `V1` on a context or input variant identifies that
//! structure's SVM wire-schema revision. Those schemas evolve independently: append a new input variant for a changed
//! Deposit or Fill payload, and use a new Gateway dispatch ABI and adapter entrypoint for a changed context.

pub mod accounts;
pub mod codec;
pub mod fill_status;
pub mod jit;

#[cfg(test)]
mod tests;
