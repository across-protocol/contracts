// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// How to run (zero-arg, reads from deployed addresses for the ChainConfig):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
//
// NOTE: under Registry Routes the impl is chain-agnostic — its only constructor arg is the
// ChainConfig registry address. The SpokePool, signer, wrapped-native token, and per-leaf input
// token are all resolved from the registry at execute time.
contract DeployCounterfactualDepositSpokePool is CounterfactualConfig {
    /// @notice Zero-arg entry point: resolves the registry address from deployed-addresses.json.
    function run() external {
        address registry = _resolveChainConfig();
        require(registry != address(0), "ChainConfig not deployed on this chain");
        this.run(registry);
    }

    function run(address registry) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(registry != address(0), "Registry cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositSpokePool).creationCode,
            abi.encode(registry)
        );
        console.log("Deploying CounterfactualDepositSpokePool via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Registry:", registry);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePool deployed to:", deployed);
    }
}
