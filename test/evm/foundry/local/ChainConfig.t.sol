// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ChainConfig } from "../../../../contracts/periphery/counterfactual/ChainConfig.sol";
import {
    SPOKE_POOL_ID,
    CCTP_SRC_PERIPHERY_ID,
    OFT_SRC_PERIPHERY_ID,
    USDC_ID,
    USDT_ID,
    WRAPPED_NATIVE_ID,
    NATIVE_ASSET_TOKEN_ID
} from "../../../../contracts/periphery/counterfactual/ChainConfigIds.sol";

contract ChainConfigTest is Test {
    ChainConfig public registry;
    address public owner;
    address public newOwner;
    address public attacker;

    function setUp() public {
        owner = makeAddr("owner");
        newOwner = makeAddr("newOwner");
        attacker = makeAddr("attacker");

        registry = new ChainConfig(owner);
    }

    // --- Construction ---

    function testOwnerSetAtConstruction() public view {
        assertEq(registry.owner(), owner, "owner should be set");
    }

    function testUnsetReadsReturnZero() public view {
        assertEq(registry.bridges(SPOKE_POOL_ID), address(0));
        assertEq(registry.tokens(USDC_ID), address(0));
        assertEq(registry.cctpSourceDomain(), 0);
        assertEq(registry.oftSrcEid(), 0);
        assertEq(registry.signer(), address(0));
    }

    // --- setBridge ---

    function testSetBridgeOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setBridge(SPOKE_POOL_ID, address(0xBEEF));
    }

    function testSetBridgeEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ChainConfig.BridgeSet(SPOKE_POOL_ID, address(0xBEEF));

        vm.prank(owner);
        registry.setBridge(SPOKE_POOL_ID, address(0xBEEF));

        assertEq(registry.bridges(SPOKE_POOL_ID), address(0xBEEF));
    }

    function testSetBridgeCanClear() public {
        vm.prank(owner);
        registry.setBridge(CCTP_SRC_PERIPHERY_ID, address(0xCAFE));
        assertEq(registry.bridges(CCTP_SRC_PERIPHERY_ID), address(0xCAFE));

        vm.expectEmit(true, true, true, true);
        emit ChainConfig.BridgeSet(CCTP_SRC_PERIPHERY_ID, address(0));

        vm.prank(owner);
        registry.setBridge(CCTP_SRC_PERIPHERY_ID, address(0));
        assertEq(registry.bridges(CCTP_SRC_PERIPHERY_ID), address(0));
    }

    function testSetBridgeOverwrite() public {
        vm.prank(owner);
        registry.setBridge(SPOKE_POOL_ID, address(0x1));
        vm.prank(owner);
        registry.setBridge(SPOKE_POOL_ID, address(0x2));
        assertEq(registry.bridges(SPOKE_POOL_ID), address(0x2));
    }

    // --- setToken ---

    function testSetTokenOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setToken(USDC_ID, address(0xBEEF));
    }

    function testSetTokenEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ChainConfig.TokenSet(USDC_ID, address(0xBEEF));

        vm.prank(owner);
        registry.setToken(USDC_ID, address(0xBEEF));
        assertEq(registry.tokens(USDC_ID), address(0xBEEF));
    }

    function testSetTokenCanClear() public {
        vm.prank(owner);
        registry.setToken(USDT_ID, address(0xC0DE));
        vm.prank(owner);
        registry.setToken(USDT_ID, address(0));
        assertEq(registry.tokens(USDT_ID), address(0));
    }

    function testSetTokenWrappedNativeId() public {
        vm.prank(owner);
        registry.setToken(WRAPPED_NATIVE_ID, address(0xFADE));
        assertEq(registry.tokens(WRAPPED_NATIVE_ID), address(0xFADE));
    }

    function testSetTokenNativeAssetSentinel() public {
        address sentinel = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        vm.prank(owner);
        registry.setToken(NATIVE_ASSET_TOKEN_ID, sentinel);

        assertEq(registry.tokens(NATIVE_ASSET_TOKEN_ID), sentinel);
    }

    // --- Scalars ---

    function testSetCctpSourceDomain() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setCctpSourceDomain(7);

        vm.expectEmit(true, true, true, true);
        emit ChainConfig.CctpSourceDomainSet(7);
        vm.prank(owner);
        registry.setCctpSourceDomain(7);

        assertEq(registry.cctpSourceDomain(), 7);
    }

    function testSetOftSrcEid() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setOftSrcEid(30101);

        vm.expectEmit(true, true, true, true);
        emit ChainConfig.OftSrcEidSet(30101);
        vm.prank(owner);
        registry.setOftSrcEid(30101);

        assertEq(registry.oftSrcEid(), 30101);
    }

    function testSetSigner() public {
        address newSigner = makeAddr("signer");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setSigner(newSigner);

        vm.expectEmit(true, true, true, true);
        emit ChainConfig.SignerSet(newSigner);
        vm.prank(owner);
        registry.setSigner(newSigner);

        assertEq(registry.signer(), newSigner);
    }

    // --- Ownable2Step ---

    function testTwoStepOwnershipTransfer() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        // Ownership not yet transferred — pending only.
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), newOwner);

        // Old owner still works.
        vm.prank(owner);
        registry.setBridge(SPOKE_POOL_ID, address(0x1));

        // Wrong caller cannot accept.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.acceptOwnership();

        // New owner accepts.
        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);

        // Old owner now rejected.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registry.setBridge(SPOKE_POOL_ID, address(0x2));

        // New owner can mutate.
        vm.prank(newOwner);
        registry.setBridge(SPOKE_POOL_ID, address(0x2));
        assertEq(registry.bridges(SPOKE_POOL_ID), address(0x2));
    }

    // --- Distinct ID spaces ---

    function testBridgeAndTokenIdSpacesAreDistinct() public {
        // Same numeric id, different mapping.
        vm.prank(owner);
        registry.setBridge(1, address(0xAA));
        vm.prank(owner);
        registry.setToken(1, address(0xBB));

        assertEq(registry.bridges(1), address(0xAA));
        assertEq(registry.tokens(1), address(0xBB));
    }
}
