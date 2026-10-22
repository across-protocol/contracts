// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and a NODE_URL_<chainId> entry for the target chain.
// 2. Simulate: forge script script/periphery/DeployAcrossEventEmitter.s.sol:DeployAcrossEventEmitter \
//                --rpc-url $NODE_URL_<chainId> -vvvv
// 3. Deploy by adding --broadcast --slow.
//
// AcrossEventEmitter is a stateless metadata sink: anyone can call emitData and off-chain consumers index the
// resulting MetadataEmitted logs by emitter address. Holding one address across chains keeps that lookup
// chain-independent, so this script deploys the *recorded* creationCode rather than
// type(AcrossEventEmitter).creationCode: the fleet's instances were built with solc 0.8.23 under
// hardhat-deploy, and recompiling the (unchanged) source with the repo's current solc produces different
// initcode and therefore a different CREATE2 address. Deploying the recorded bytes keeps every chain
// byte-identical.
//
// MegaETH (4326), Arc (5042) and Avalanche (43114) hold separately-compiled instances at other addresses.
// Resolve the emitter per chain via getDeployedAddress rather than assuming CANONICAL.
contract DeployAcrossEventEmitter is DeploymentUtils {
    /// @dev The address AcrossEventEmitter occupies on every chain this script deploys to.
    address internal constant CANONICAL = 0xBF75133b48b0a42AB9374027902E83C5E2949034;

    /// @dev Salt used by the original hardhat-deploy deployments.
    bytes32 internal constant SALT = bytes32(uint256(0x1234));

    /// @dev Any chain's record works; they all hold identical bytes. Mainnet is the reference.
    string internal constant REFERENCE = "deployments/mainnet/AcrossEventEmitter.json";

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
        console.log("Across event emitter deployed to:", deployed);
    }
}
