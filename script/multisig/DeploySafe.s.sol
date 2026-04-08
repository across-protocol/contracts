// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address _singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);

    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);
}

// How to run:
// 1. source .env (needs MNEMONIC="x x x ... x")
// 2. Update safe-config.toml with desired owners and threshold.
// 3. Simulate: forge script script/multisig/DeploySafe.s.sol:DeploySafe --rpc-url <rpc> -vvvv
// 4. Deploy:   forge script script/multisig/DeploySafe.s.sol:DeploySafe --rpc-url <rpc> --broadcast -vvvv
contract DeploySafe is Script, Test {
    // Struct field order must be alphabetical by TOML key for vm.parseToml decoding.
    struct SafeInfra {
        address fallback_handler;
        address proxy_factory;
        address singleton;
    }

    struct MultisigParams {
        address[] owners;
        uint256 salt_nonce;
        uint256 threshold;
    }

    function run() external {
        console.log("=== Deploy Safe Multisig ===");
        console.log("Chain ID:", block.chainid);

        // --- 1. Load config ---
        string memory toml = vm.readFile("./script/multisig/safe-config.toml");
        SafeInfra memory safe = abi.decode(vm.parseToml(toml, ".safe"), (SafeInfra));
        MultisigParams memory params = abi.decode(vm.parseToml(toml, ".multisig"), (MultisigParams));

        require(params.owners.length > 0, "No owners configured");
        require(params.threshold > 0 && params.threshold <= params.owners.length, "Invalid threshold");

        console.log("Owners:", params.owners.length);
        console.log("Threshold:", params.threshold);

        // --- 2. Verify Safe infrastructure is deployed ---
        require(safe.proxy_factory.code.length > 0, "SafeProxyFactory not deployed on this chain");
        require(safe.singleton.code.length > 0, "Safe singleton not deployed on this chain");
        require(safe.fallback_handler.code.length > 0, "CompatibilityFallbackHandler not deployed on this chain");

        // --- 4. Build initializer calldata ---
        bytes memory initializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            params.owners,
            params.threshold,
            address(0), // to — no delegate call at setup
            "", // data
            safe.fallback_handler,
            address(0), // paymentToken
            0, // payment
            address(0) // paymentReceiver
        );

        // --- 5. Predict Safe address ---
        address predictedAddress = _predictSafeAddress(
            safe.proxy_factory,
            safe.singleton,
            initializer,
            params.salt_nonce
        );
        console.log("Predicted Safe address:", predictedAddress);

        // --- 6. Check if already deployed ---
        if (predictedAddress.code.length > 0) {
            console.log("Safe already deployed at predicted address. Skipping.");
            _verifyDeployment(predictedAddress, params);
            return;
        }

        // --- 7. Deploy ---
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        address safe_ = ISafeProxyFactory(safe.proxy_factory).createProxyWithNonce(
            safe.singleton,
            initializer,
            params.salt_nonce
        );

        vm.stopBroadcast();

        console.log("Safe deployed at:", safe_);

        // --- 8. Post-deployment verification ---
        assertEq(safe_, predictedAddress, "Deployed address does not match prediction");
        _verifyDeployment(safe_, params);
    }

    function _predictSafeAddress(
        address proxyFactory,
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes memory proxyCreationCode = ISafeProxyFactory(proxyFactory).proxyCreationCode();
        bytes memory deploymentData = abi.encodePacked(proxyCreationCode, uint256(uint160(singleton)));
        return
            address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), proxyFactory, salt, keccak256(deploymentData))))
                )
            );
    }

    function _verifyDeployment(address safe_, MultisigParams memory params) internal view {
        address[] memory owners = ISafe(safe_).getOwners();
        uint256 threshold = ISafe(safe_).getThreshold();

        assertEq(owners.length, params.owners.length, "Owner count mismatch");
        // Safe's linked list may return owners in a different order than the config.
        // Verify that every configured owner is present on-chain.
        for (uint256 i = 0; i < params.owners.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < owners.length; j++) {
                if (owners[j] == params.owners[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string(abi.encodePacked("Owner not found: ", vm.toString(params.owners[i]))));
        }
        assertEq(threshold, params.threshold, "Threshold mismatch");

        console.log("Verification passed: owners and threshold match config");
    }
}
