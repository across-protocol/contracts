// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";

import { HubPool } from "../../contracts/HubPool.sol";
import { SpokePool } from "../../contracts/SpokePool.sol";
import { LpTokenFactory } from "../../contracts/LpTokenFactory.sol";
import { PermissionSplitterProxy } from "../../contracts/PermissionSplitterProxy.sol";

// Run this test to verify PermissionSplitter behavior when changing ownership of the HubPool
// to it. Therefore this test should be run as a fork test via:
// - forge test --fork-url <MAINNET-RPC-URL>
contract PermissionSplitterTest is Test {
    HubPool hubPool;
    HubPool hubPoolProxy;
    SpokePool ethereumSpokePool;
    PermissionSplitterProxy permissionSplitter;

    // defaultAdmin is the deployer of the PermissionSplitter and has authority
    // to call any function on the HubPool. Therefore this should be a highly secure
    // contract account such as a MultiSig contract.
    address defaultAdmin;
    // Pause admin should only be allowed to pause the HubPool.
    address pauseAdmin;

    // HubPool function selectors:
    bytes4 constant PAUSE_SELECTOR = bytes4(keccak256("setPaused(bool)"));
    bytes4 constant DELETE_PROPOSAL_SELECTOR = bytes4(keccak256("emergencyDeleteProposal()"));
    bytes4 constant RELAY_SPOKEPOOL_SELECTOR = bytes4(keccak256("relaySpokePoolAdminFunction(uint256,bytes)"));
    bytes4 constant SET_PROTOCOL_FEE_SELECTOR = bytes4(keccak256("setProtocolFeeCapture(address,uint256)"));
    bytes4 constant SET_BOND_SELECTOR = bytes4(keccak256("setBond(address,uint256)"));
    bytes4 constant SET_LIVENESS_SELECTOR = bytes4(keccak256("setLiveness(uint32)"));
    bytes4 constant SET_IDENTIFIER_SELECTOR = bytes4(keccak256("setIdentifier(bytes32)"));
    bytes4 constant SET_XCHAIN_CONTRACTS_SELECTOR =
        bytes4(keccak256("setCrossChainContracts(uint256,address,address)"));
    bytes4 constant SET_POOL_REBALANCE_ROUTES_SELECTOR =
        bytes4(keccak256("setPoolRebalanceRoute(uint256,address,address)"));
    bytes4 constant SET_DEPOSIT_ROUTES_SELECTOR = bytes4(keccak256("setDepositRoute(uint256,uint256,address,bool)"));
    bytes4 constant ENABLE_L1_TOKEN_SELECTOR = bytes4(keccak256("enableL1TokenForLiquidityProvision(address)"));
    bytes4 constant DISABLE_L1_TOKEN_SELECTOR = bytes4(keccak256("disableL1TokenForLiquidityProvision(address)"));
    bytes4 constant HAIRCUT_RESERVES_SELECTOR = bytes4(keccak256("haircutReserves(address,int256)"));
    bytes4 constant ADD_LIQUIDITY_SELECTOR = bytes4(keccak256("addLiquidity(address,int256)"));
    bytes4 constant REMOVE_LIQUIDITY_SELECTOR = bytes4(keccak256("removeLiquidity(address,int256,bool)"));
    bytes4 constant EXCHANGE_RATE_SELECTOR = bytes4(keccak256("exchangeRateCurrent(address)"));
    bytes4 constant UTILIZATION_SELECTOR = bytes4(keccak256("liquidityUtilizationCurrent(address)"));
    bytes4 constant UTILIZATION_POST_RELAY_SELECTOR =
        bytes4(keccak256("liquidityUtilizationPostRelay(address,uint256)"));
    bytes4 constant SYNC_SELECTOR = bytes4(keccak256("sync(address)"));
    bytes4 constant PROPOSE_SELECTOR = bytes4(keccak256("proposeRootBundle(uint256[],uint8,bytes32,bytes32,bytes32)"));
    bytes4 constant EXECUTE_SELECTOR =
        bytes4(keccak256("executeRootBundle(uint256,uint256,uint256[],int256[],int256[],uint8,address[],bytes32[])"));
    bytes4 constant DISPUTE_SELECTOR = bytes4(keccak256("disputeRootBundle()"));
    bytes4 constant CLAIM_FEES_SELECTOR = bytes4(keccak256("claimProtocolFeesCaptured(address)"));
    bytes4 constant LOAD_ETH_SELECTOR = bytes4(keccak256("loadEthForL2Calls()"));

    // PermissionSplitterProxy function selectors:
    bytes4 constant SET_ROLE_SELECTOR = bytes4(keccak256("__setRoleForSelector(bytes4,bytes32)"));
    bytes4 constant SET_TARGET_SELECTOR = bytes4(keccak256("__setTarget(address)"));

    bytes4[] hubPoolSelectors = [
        PAUSE_SELECTOR,
        DELETE_PROPOSAL_SELECTOR,
        RELAY_SPOKEPOOL_SELECTOR,
        SET_PROTOCOL_FEE_SELECTOR,
        SET_BOND_SELECTOR,
        SET_LIVENESS_SELECTOR,
        SET_IDENTIFIER_SELECTOR,
        SET_XCHAIN_CONTRACTS_SELECTOR,
        SET_POOL_REBALANCE_ROUTES_SELECTOR,
        SET_DEPOSIT_ROUTES_SELECTOR,
        ENABLE_L1_TOKEN_SELECTOR,
        DISABLE_L1_TOKEN_SELECTOR,
        HAIRCUT_RESERVES_SELECTOR,
        ADD_LIQUIDITY_SELECTOR,
        REMOVE_LIQUIDITY_SELECTOR,
        EXCHANGE_RATE_SELECTOR,
        UTILIZATION_SELECTOR,
        UTILIZATION_POST_RELAY_SELECTOR,
        SYNC_SELECTOR,
        PROPOSE_SELECTOR,
        EXECUTE_SELECTOR,
        DISPUTE_SELECTOR,
        CLAIM_FEES_SELECTOR,
        LOAD_ETH_SELECTOR
    ];
    bytes4[] proxySelectors = [SET_ROLE_SELECTOR, SET_TARGET_SELECTOR];

    bytes32 constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    // Error emitted when non-owner calls onlyOwner HubPool function.
    bytes constant OWNABLE_NOT_OWNER_ERROR = bytes("Ownable: caller is not the owner");
    // Error emitted when calling PermissionSplitterProxy function with incorrect role.
    bytes constant PROXY_NOT_ALLOWED_TO_CALL_ERROR = bytes("Not allowed to call");

    address constant WETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    error FuncSelectorCollision();

    function setUp() public {
        // Since this test file is designed to run against a mainnet fork, hardcode the following system
        // contracts to skip the setup we'd usually need to run to use brand new contracts.
        hubPool = HubPool(payable(0xc186fA914353c44b2E33eBE05f21846F1048bEda));
        ethereumSpokePool = SpokePool(payable(0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5));

        // For the purposes of this test, the default admin will be the current owner of the
        // HubPool, which we can assume is a highly secured account.
        defaultAdmin = hubPool.owner();
        pauseAdmin = vm.addr(1);

        // Deploy PermissionSplitter from default admin account and then
        // create and assign roles.
        vm.startPrank(defaultAdmin);
        // Default admin can call any ownable function, which no one else can call without
        // the correct role.
        permissionSplitter = new PermissionSplitterProxy(address(hubPool));
        permissionSplitter.grantRole(PAUSE_ROLE, pauseAdmin);
        // Grant anyone with the pause role the ability to call setPaused
        permissionSplitter.__setRoleForSelector(PAUSE_SELECTOR, PAUSE_ROLE);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        hubPool.transferOwnership(address(permissionSplitter));
        hubPoolProxy = HubPool(payable(permissionSplitter));
    }

    function testPause() public {
        // Calling HubPool setPaused directly should fail, even if called by previous owner.
        vm.startPrank(defaultAdmin);
        vm.expectRevert(OWNABLE_NOT_OWNER_ERROR);
        hubPool.setPaused(true);
        vm.stopPrank();

        // Must call HubPool via PermissionSplitterProxy.
        vm.prank(pauseAdmin);
        hubPoolProxy.setPaused(true);
        assertTrue(hubPool.paused());

        // Can also call Proxy function via default admin.
        vm.prank(defaultAdmin);
        hubPoolProxy.setPaused(false);
        assertFalse(hubPool.paused());
    }

    function testCallSpokePoolFunction() public {
        bytes32 fakeRoot = keccak256("new admin root");
        bytes memory spokeFunctionCallData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            fakeRoot,
            fakeRoot
        );
        uint256 spokeChainId = 1;

        vm.expectRevert(PROXY_NOT_ALLOWED_TO_CALL_ERROR);
        hubPoolProxy.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);
        vm.expectRevert(OWNABLE_NOT_OWNER_ERROR);
        hubPool.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);

        vm.startPrank(defaultAdmin);
        vm.expectCall(address(ethereumSpokePool), spokeFunctionCallData);
        hubPoolProxy.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);
        vm.stopPrank();
    }

    function testFallback() public {
        // Calling a function that doesn't exist on target or PermissionSplitter calls the HubPool's
        // fallback function which wraps any msg.value into wrapped native token.
        uint256 balBefore = address(hubPool).balance;

        // Calling fake function as admin with no value succeeds and does nothing.
        vm.prank(defaultAdmin);
        (bool success1, ) = address(hubPoolProxy).call("doesNotExist()");
        assertTrue(success1);

        // Calling fake function as admin with value also succeeds and wraps the msg.value
        // and then does nothing.
        vm.deal(defaultAdmin, 1 ether);
        vm.prank(defaultAdmin);
        (bool success2, bytes memory reason) = address(hubPoolProxy).call{ value: 1 ether }("doesNotExist()");
        assertTrue(success2);
        assertEq(address(hubPool).balance, balBefore);
    }

    /// forge-config: default.fuzz.runs = 100
    function testFunctionSelectorCollisions(uint256 hubPoolFuncSelectorIdx, uint256 proxyFuncSelectorIdx) public {
        vm.assume(hubPoolFuncSelectorIdx < hubPoolSelectors.length);
        vm.assume(proxyFuncSelectorIdx < proxySelectors.length);

        // Assert that PermissionSplitter has no function selector collisions with HubPool.
        // @dev Solidity compilation will fail if function selectors on the same contract collide.
        // - https://ethereum.stackexchange.com/a/46188/47801
        if (hubPoolSelectors[hubPoolFuncSelectorIdx] == proxySelectors[proxyFuncSelectorIdx])
            revert FuncSelectorCollision();
    }

    function testCallPublicFunction() public {
        // Should be able to call public functions without any access modifiers via proxy as the default admin.

        vm.prank(defaultAdmin);
        hubPoolProxy.sync(WETHAddress);

        vm.expectRevert(PROXY_NOT_ALLOWED_TO_CALL_ERROR);
        hubPoolProxy.sync(WETHAddress);
    }
}
