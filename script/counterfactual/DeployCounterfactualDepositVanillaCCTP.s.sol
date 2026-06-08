// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositVanillaCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositVanillaCCTP.sol";

// Deploys CounterfactualDepositVanillaCCTP — the non-sponsored CCTP v2 route that calls Circle's
// TokenMessenger directly. Resolves the chain's CCTP v2 TokenMessenger from constants.json and the fee
// `signer` from config.toml. Address is chain-specific (the TokenMessenger differs per chain).
//
// How to run (zero-arg, reads from constants + config.toml):
// 1. Edit script/counterfactual/config.toml with the signer address
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualDepositVanillaCCTP.s.sol:DeployCounterfactualDepositVanillaCCTP \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositVanillaCCTP is CounterfactualConfig {
    /// @notice Zero-arg entry point: resolves the CCTP v2 TokenMessenger and signer.
    function run() external {
        address tokenMessenger = _resolveCctpV2TokenMessenger();
        require(tokenMessenger != address(0), "CCTP v2 TokenMessenger not available on this chain");
        this.run(tokenMessenger, _loadSigner());
    }

    function run(address tokenMessenger, address signer) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(tokenMessenger != address(0), "TokenMessenger cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositVanillaCCTP).creationCode,
            abi.encode(tokenMessenger, signer)
        );
        console.log("Deploying CounterfactualDepositVanillaCCTP via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("TokenMessenger:", tokenMessenger);
        console.log("Signer:", signer);

        bytes32 salt = _loadSalt();
        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositVanillaCCTP deployed to:", deployed);
    }
}
