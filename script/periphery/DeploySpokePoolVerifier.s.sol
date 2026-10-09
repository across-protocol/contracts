// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and a NODE_URL_<chainId> entry for the target chain.
// 2. Simulate: forge script script/periphery/DeploySpokePoolVerifier.s.sol:DeploySpokePoolVerifier \
//                --rpc-url $NODE_URL_<chainId> -vvvv
// 3. Deploy by adding --broadcast --slow.
//
// SpokePoolVerifier only does its job if it lives at the SAME address on every chain. It is a passthrough for
// native-token deposits that reverts when the SpokePool the caller named does not exist on the current chain, so
// a deposit broadcast to the wrong chain reverts instead of paying native tokens into a codeless address. That
// protection depends entirely on the address matching, which is why this script refuses to deploy anywhere else.
//
// Note it deploys the *recorded* creationCode rather than type(SpokePoolVerifier).creationCode: the fleet's
// instances were built with solc 0.8.19 under hardhat-deploy, and recompiling the (unchanged) source with the
// repo's current solc produces different initcode and therefore a different CREATE2 address. Deploying the
// recorded bytes keeps every chain byte-identical.
contract DeploySpokePoolVerifier is DeploymentUtils {
    /// @dev The address SpokePoolVerifier occupies on every chain it is deployed to.
    address internal constant CANONICAL = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;

    /// @dev Salt used by the original hardhat-deploy deployments.
    bytes32 internal constant SALT = bytes32(uint256(0x1234));

    /// @dev Any chain's record works; they all hold identical bytes. Mainnet is the reference.
    string internal constant REFERENCE = "deployments/mainnet/SpokePoolVerifier.json";

    function run() external {
        console.log("=== Chain", block.chainid, "===");

        bytes memory initCode = vm.parseJsonBytes(vm.readFile(REFERENCE), ".bytecode");
        require(
            _predictCreate2(SALT, initCode) == CANONICAL,
            "reference initCode + salt do not reproduce the canonical address"
        );

        if (CANONICAL.code.length > 0) {
            console.log("Already deployed at:", CANONICAL);
            return;
        }

        vm.startBroadcast(vm.deriveKey(vm.envString("MNEMONIC"), 0));
        address deployed = _deployCreate2(SALT, initCode);
        vm.stopBroadcast();

        require(deployed == CANONICAL, "deployed to an unexpected address");
        console.log("Spoke pool verifier deployed to:", deployed);
    }
}
