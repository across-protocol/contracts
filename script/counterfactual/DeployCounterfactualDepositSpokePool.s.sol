// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// How to run (zero-arg, reads from config.toml + constants):
// 1. Edit script/counterfactual/config.toml with signer address
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePool is CounterfactualConfig {
    /// @notice Zero-arg entry point: resolves all params from config.toml and on-chain constants.
    function run() external {
        address signer = _loadSigner();
        this.run(_resolveSpokePool(), signer, _resolveWrappedNativeToken());
    }

    function run(address spokePool, address signer, address wrappedNativeToken) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(spokePool != address(0), "SpokePool cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");
        require(wrappedNativeToken != address(0), "Wrapped native token cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositSpokePool).creationCode,
            abi.encode(spokePool, signer, wrappedNativeToken)
        );
        console.log("Deploying CounterfactualDepositSpokePool via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("SpokePool:", spokePool);
        console.log("Signer:", signer);
        console.log("Wrapped native token:", wrappedNativeToken);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePool deployed to:", deployed);
    }
}
