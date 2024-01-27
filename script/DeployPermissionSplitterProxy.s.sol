// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";

import { PermissionSplitterProxy } from "../contracts/PermissionSplitterProxy.sol";

// How to run:
// 1. `source .env` where `.env has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/DeployPermissionSplitterProxy.s.sol:DeployPermissionSplitterProxy --rpc-url $NODE_URL_1-vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/DeployPermissionSplitterProxy.s.sol:DeployPermissionSplitterProxy --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
contract DeployPermissionSplitterProxy is Script, Test {
    PermissionSplitterProxy permissionSplitter;

    address constant defaultAdmin = 0xB524735356985D2f267FA010D681f061DfF03715;
    address constant hubPool = 0xc186fA914353c44b2E33eBE05f21846F1048bEda;

    bytes4 constant PAUSE_SELECTOR = bytes4(keccak256("setPaused(bool)"));
    bytes32 constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployerPublicKey = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        permissionSplitter = new PermissionSplitterProxy(hubPool);

        // Give default admin the pause role.
        permissionSplitter.grantRole(PAUSE_ROLE, defaultAdmin);
        // Grant anyone with the pause role the ability to call setPaused.
        permissionSplitter.__setRoleForSelector(PAUSE_SELECTOR, PAUSE_ROLE);
        // Revoke the deployer's default admin role.
        permissionSplitter.renounceRole(DEFAULT_ADMIN_ROLE, deployerPublicKey);

        // Sanity check.
        assertTrue(permissionSplitter.hasRole(PAUSE_ROLE, defaultAdmin));
        assertFalse(permissionSplitter.hasRole(PAUSE_ROLE, deployerPublicKey));
        assertFalse(permissionSplitter.hasRole(DEFAULT_ADMIN_ROLE, deployerPublicKey));
        assertTrue(permissionSplitter.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
    }
}
