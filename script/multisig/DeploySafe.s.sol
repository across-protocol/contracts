// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

// Minimal interfaces for interacting with Safe v1.4.1 contracts. We only define the functions
// we need rather than importing the full Safe source (which uses solc 0.7.6).

interface ISafeProxyFactory {
    /// @dev Deploys a new Safe proxy via CREATE2. The proxy delegates all calls to `_singleton`.
    /// The deterministic address is derived from: factory address, keccak256(keccak256(initializer), saltNonce),
    /// and keccak256(proxyCreationCode ++ singleton). Identical inputs on any chain = identical address.
    function createProxyWithNonce(
        address _singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);

    /// @dev Returns the SafeProxy creation bytecode. Needed to predict the CREATE2 address off-chain.
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafe {
    /// @dev Initializes a Safe proxy. Called once by the factory immediately after CREATE2 deployment.
    /// The full calldata of this function is hashed into the CREATE2 salt, so any parameter change
    /// (even zero vs non-zero `payment`) produces a different deployed address.
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

// Deploys a Safe multisig to deterministic addresses across EVM chains.
//
// The same config (owners, threshold, salt_nonce) produces the same Safe address on every chain,
// enabling consistent multisig addresses across all chains Across supports. This is achieved via
// CREATE2 through the canonical SafeProxyFactory, which is deployed to the same address on all
// chains by the Safe Singleton Factory (0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7).
//
// The initializer calldata matches the Safe UI's L2 deployment pattern so that deployed Safes
// are fully compatible with the Safe web interface and transaction service on L2 chains.
//
// How to run:
// 1. source .env (needs MNEMONIC="x x x ... x")
// 2. Update safe-config.toml with desired owners and threshold.
// 3. Simulate: forge script script/multisig/DeploySafe.s.sol:DeploySafe --rpc-url <rpc> -vvvv
// 4. Deploy:   forge script script/multisig/DeploySafe.s.sol:DeploySafe --rpc-url <rpc> --broadcast -vvvv
contract DeploySafe is Script, Test {
    // Struct field order must be alphabetical by TOML key name. Foundry's vm.parseToml() returns
    // ABI-encoded fields sorted alphabetically by key, so the struct declaration must match that
    // order. Mismatched ordering silently decodes values into the wrong fields.
    struct SafeInfra {
        address fallback_handler;
        address proxy_factory;
        address safe_l2;
        address safe_to_l2_setup;
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
        // All of these are deployed to the same canonical addresses on every chain via the Safe
        // Singleton Factory. If any are missing, the chain likely doesn't have Safe support yet.
        require(safe.proxy_factory.code.length > 0, "SafeProxyFactory not deployed on this chain");
        require(safe.singleton.code.length > 0, "Safe singleton not deployed on this chain");
        require(safe.fallback_handler.code.length > 0, "CompatibilityFallbackHandler not deployed on this chain");
        require(safe.safe_to_l2_setup.code.length > 0, "SafeToL2Setup not deployed on this chain");
        require(safe.safe_l2.code.length > 0, "SafeL2 not deployed on this chain");

        // --- 3. Build initializer calldata ---
        // This matches the exact calldata the Safe UI produces for L2 deployments.
        //
        // The Safe UI's L2 pattern delegate-calls SafeToL2Setup during setup, which swaps the
        // proxy's singleton from Safe to SafeL2. SafeL2 emits additional events containing full
        // transaction data in logs, which L2 indexers need since they can't efficiently trace
        // internal calls. Without this, the Safe works on-chain but won't display correctly in
        // the Safe UI or transaction service.
        bytes memory setupToL2Data = abi.encodeWithSelector(
            // setupToL2(address) - selector from SafeToL2Setup contract. Takes the SafeL2
            // implementation address and updates the proxy's singleton storage slot to point to it.
            bytes4(0xfe51f643),
            safe.safe_l2
        );
        bytes memory initializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            params.owners,
            params.threshold,
            // `to` and `data`: delegate-call target and calldata executed during setup.
            // SafeToL2Setup.setupToL2() swaps the singleton from Safe to SafeL2.
            safe.safe_to_l2_setup,
            setupToL2Data,
            safe.fallback_handler,
            address(0), // paymentToken - unused (legacy gas sponsorship: token to reimburse deployer)
            0, // payment - unused (legacy gas sponsorship: amount to reimburse)
            // paymentReceiver - no-op vanity address used by the Safe UI as a deployment marker.
            // "5afe7A11E7" = "SafeAllE7". No code at this address; since payment is 0, nothing is sent.
            // Must match the Safe UI's value to produce the same CREATE2 address.
            address(0x5afe7A11E7000000000000000000000000000000)
        );

        // --- 4. Predict Safe address ---
        // Computes the CREATE2 address without deploying. Used to check idempotency and verify
        // the deployment landed at the expected address.
        address predictedAddress = _predictSafeAddress(
            safe.proxy_factory,
            safe.singleton,
            initializer,
            params.salt_nonce
        );
        console.log("Predicted Safe address:", predictedAddress);

        // --- 5. Check if already deployed (idempotent) ---
        if (predictedAddress.code.length > 0) {
            console.log("Safe already deployed at predicted address. Skipping.");
            _verifyDeployment(predictedAddress, params);
            return;
        }

        // --- 6. Deploy ---
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // The factory deploys a minimal SafeProxy via CREATE2, then calls setup() on it.
        // The proxy stores the singleton address at storage slot 0 and delegatecalls all
        // functions to it. Note: `singleton` here is the initial singleton passed to the factory;
        // the SafeToL2Setup delegate-call in setup() will immediately overwrite it with SafeL2.
        address safe_ = ISafeProxyFactory(safe.proxy_factory).createProxyWithNonce(
            safe.singleton,
            initializer,
            params.salt_nonce
        );

        vm.stopBroadcast();

        console.log("Safe deployed at:", safe_);

        // --- 7. Post-deployment verification ---
        assertEq(safe_, predictedAddress, "Deployed address does not match prediction");
        _verifyDeployment(safe_, params);
    }

    /// @dev Predicts the CREATE2 address for a Safe proxy deployed via SafeProxyFactory.
    /// Reproduces the factory's internal address computation:
    ///   salt       = keccak256(abi.encodePacked(keccak256(initializer), saltNonce))
    ///   initCode   = proxyCreationCode ++ uint256(singleton)
    ///   address    = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
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

    /// @dev Verifies that the deployed Safe has the expected owners and threshold.
    /// Owner order is not checked because Safe stores owners in a linked list whose iteration
    /// order may differ from the input order. Instead we verify set membership + count.
    function _verifyDeployment(address safe_, MultisigParams memory params) internal view {
        address[] memory owners = ISafe(safe_).getOwners();
        uint256 threshold = ISafe(safe_).getThreshold();

        assertEq(owners.length, params.owners.length, "Owner count mismatch");
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
