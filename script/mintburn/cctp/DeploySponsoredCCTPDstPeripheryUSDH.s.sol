// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploySponsoredCCTPDstPeripheryUSDC } from "./DeploySponsoredCCTPDstPeripheryUSDC.s.sol";

// How to run:
// 1. Add `usdh = "0x..."` under the target chain's `[<chain>.address]` block in
//    script/mintburn/cctp/config.toml.
// 2. source .env (needs MNEMONIC="x x x ... x")
// 3. Simulate: forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeripheryUSDH.s.sol:DeploySponsoredCCTPDstPeripheryUSDH --rpc-url <network> -vvvv
// 4. Deploy:   forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeripheryUSDH.s.sol:DeploySponsoredCCTPDstPeripheryUSDH --rpc-url <network> --broadcast --verify -vvvv
contract DeploySponsoredCCTPDstPeripheryUSDH is DeploySponsoredCCTPDstPeripheryUSDC {
    function run() external override {
        _loadConfig(CONFIG_PATH, true);
        _deploy("usdh");
    }
}
