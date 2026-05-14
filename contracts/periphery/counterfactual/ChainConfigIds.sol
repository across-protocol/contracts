// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Stable, chain-agnostic IDs used by counterfactual deposit implementations to look up
// chain-specific addresses from `ChainConfig`. The same ID means the same thing on every
// chain — `USDC_ID = 1` is USDC everywhere it exists.
//
// Bridge IDs and token IDs share no key space; they live in separate registry mappings.

// --- Bridge IDs ---
uint32 constant SPOKE_POOL_ID = 1;
uint32 constant CCTP_SRC_PERIPHERY_ID = 2;
uint32 constant OFT_SRC_PERIPHERY_ID = 3;

// --- Token IDs ---
uint32 constant USDC_ID = 1;
uint32 constant USDT_ID = 2;
uint32 constant DAI_ID = 3;

// Wrapped native (e.g. WETH on Ethereum, WMATIC on Polygon).
uint32 constant WRAPPED_NATIVE_ID = 99;

// Reserved sentinel: when an impl resolves `tokens[NATIVE_ASSET_TOKEN_ID]` it must get back the
// `NATIVE_ASSET` sentinel address (0xEee…EEeE). Operators MUST set this on every chain.
uint32 constant NATIVE_ASSET_TOKEN_ID = type(uint32).max;
