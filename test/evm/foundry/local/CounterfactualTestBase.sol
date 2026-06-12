// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBase } from "../../../../contracts/periphery/counterfactual/CounterfactualBeaconBase.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";

/**
 * @title CounterfactualTestBase
 * @notice Shared harness for the beacon-based counterfactual tests. Tests build a
 *         `CounterfactualChainConfig` from their mocks then call `_deployBeacon(config)`, which deploys the
 *         beacon (UUPS proxy over `CounterfactualDeposit`) plus the factory. Provides merkle/leaf/EIP-712
 *         helpers.
 * @dev Deploy order resolves the beacon ⇄ implementation cycle: (1) beacon proxy with `implementation = 0`,
 *      (2) `CounterfactualDeposit` bound to the beacon, (3) `beacon.setImplementation(impl)`.
 */
abstract contract CounterfactualTestBase is Test {
    Merkle internal merkle;

    CounterfactualBeacon internal beacon; // beacon (UUPS proxy)
    CounterfactualDeposit internal cfImpl; // beacon target implementation
    CounterfactualDepositFactory internal factory;
    WithdrawImplementation internal withdrawImpl;

    address internal owner; // beacon admin
    address internal user; // withdraw user
    address internal admin; // withdraw admin
    address internal relayer; // executor / fee recipient

    uint256 internal signerPk;
    address internal signer; // off-chain fee signer used by the bridge impls

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant VERSION_HASH = keccak256("v2.0.0");

    /// @dev Sets up actors, signer, merkle, and the withdraw impl. Does NOT deploy the beacon — call
    ///      `_deployBeacon(config)` once the test's mocks exist.
    function _setUpCore() internal {
        merkle = new Merkle();

        owner = makeAddr("owner");
        user = makeAddr("user");
        admin = makeAddr("admin");
        relayer = makeAddr("relayer");
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);

        withdrawImpl = new WithdrawImplementation();
    }

    /// @dev A config with only the fee `signer` set; tests fill in the chain-specific fields they need.
    function _baseConfig() internal view returns (CounterfactualChainConfig memory cfg) {
        cfg.signer = signer;
    }

    /// @dev Deploy the beacon (carrying `config`), wire its implementation, and deploy the factory. Call
    ///      after the test's mocks are created.
    function _deployBeacon(CounterfactualChainConfig memory config) internal {
        // Implementation set later (deploy flow: beacon → impl → setImplementation).
        beacon = CounterfactualBeacon(
            address(
                new ERC1967Proxy(
                    address(new CounterfactualBeacon(config)),
                    abi.encodeCall(CounterfactualBeaconBase.initialize, (owner, address(0), bytes32(0)))
                )
            )
        );

        cfImpl = new CounterfactualDeposit(ICounterfactualBeacon(address(beacon)));
        vm.prank(owner);
        beacon.setImplementation(address(cfImpl));

        factory = new CounterfactualDepositFactory(address(beacon));
    }

    /// @dev Deposit/withdraw leaf: double-hashed `(implementation, keccak256(params))`.
    function _leaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    /// @dev Upgrade-tree leaf: double-hashed `(proxy, root)`.
    function _upgradeLeaf(address proxy, bytes32 root) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(proxy, root))));
    }

    /// @dev Set the beacon's upgrade root to a 2-leaf tree authorizing `(proxy → newRoot)`; returns the proof.
    function _setUpgradeTree(address proxy, bytes32 newRoot) internal returns (bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _upgradeLeaf(proxy, newRoot);
        leaves[1] = keccak256("upgrade-padding");
        // Compute root/proof before pranking: the external `merkle` calls would consume the prank.
        bytes32 upgradeRoot = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        vm.prank(owner);
        beacon.setUpgradeRoot(upgradeRoot);
    }

    /// @dev EIP-712 domain separator for an impl `name` (version v2.0.0) at `verifyingContract`.
    function _domainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes(name)),
                    VERSION_HASH,
                    block.chainid,
                    verifyingContract
                )
            );
    }

    /// @dev Sign an EIP-712 `structHash` under `domainSeparator` with `pk`, returning `(r,s,v)`-packed.
    function _sign(uint256 pk, bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
