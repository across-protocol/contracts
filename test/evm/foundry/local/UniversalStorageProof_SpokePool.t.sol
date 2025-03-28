// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { UniversalStorageProof_SpokePool, IHelios } from "../../../../contracts/UniversalStorageProof_SpokePool.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import "../../../../contracts/test/MockCCTP.sol";

contract MockHelios is IHelios {
    mapping(bytes32 => bytes32) public storageSlots;

    uint256 public headTimestamp;

    function updateStorageSlot(bytes32 key, bytes32 valueHash) external {
        storageSlots[key] = valueHash;
    }

    function updateHeadTimestamp(uint256 _timestamp) external {
        headTimestamp = _timestamp;
    }

    function getStorageSlot(
        uint256,
        address,
        bytes32 _key
    ) external view returns (bytes32) {
        return storageSlots[_key];
    }
}

contract MockUniversalStorageProofSpokePool is UniversalStorageProof_SpokePool {
    constructor(
        uint256 _adminUpdateBuffer,
        address _helios,
        address _hubPoolStore,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        UniversalStorageProof_SpokePool(
            _adminUpdateBuffer,
            _helios,
            _hubPoolStore,
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger
        )
    {}

    function test_bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external {
        _bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}

contract UniversalStorageProofSpokePoolTest is Test {
    MockUniversalStorageProofSpokePool spokePool;
    MockHelios helios;

    address hubPoolStore;
    address hubPool;
    uint256 nonce = 0;
    address owner;
    address rando;
    uint256 adminUpdateBuffer = 1 days;

    ERC20 usdc;
    uint256 usdcMintAmount = 100e6;
    MockCCTPMessenger cctpMessenger;

    function setUp() public {
        helios = new MockHelios();
        usdc = new ERC20("USDC", "USDC");
        MockCCTPMinter minter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(ITokenMinter(minter));
        hubPool = makeAddr("hubPool");
        owner = vm.addr(1);
        rando = vm.addr(2);
        spokePool = new MockUniversalStorageProofSpokePool(
            adminUpdateBuffer,
            address(helios),
            hubPoolStore,
            address(0),
            7200,
            7200,
            IERC20(address(usdc)),
            ITokenMessenger(address(cctpMessenger))
        );
        vm.prank(owner);
        address proxy = address(
            new ERC1967Proxy(
                address(spokePool),
                abi.encodeCall(UniversalStorageProof_SpokePool.initialize, (0, hubPool, hubPool))
            )
        );
        spokePool = MockUniversalStorageProofSpokePool(payable(proxy));
        deal(address(usdc), address(spokePool), usdcMintAmount, true);
    }

    function testReceiveL1State() public {
        // Should be able to call relayRootBundle
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testReceiveL1State_addressZeroTarget() public {
        // Should be able to call relayRootBundle with slot value target set to zero address
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(0), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testReplayProtection() public {
        // Should not be able to receive same L1 state twice, even if block number changes.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        spokePool.receiveL1State(slotKey, value, 100);
        vm.expectRevert(UniversalStorageProof_SpokePool.AlreadyReceived.selector);
        spokePool.receiveL1State(slotKey, value, 101); // block number changes doesn't impact replay protection
    }

    function testVerifiedProofs() public {
        // Checks replay protection mapping is updated as expected.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        assertFalse(spokePool.verifiedProofs(slotKey));
        spokePool.receiveL1State(slotKey, value, 100);
        assertTrue(spokePool.verifiedProofs(slotKey));
    }

    function testHeliosMissingState() public {
        // Reverts if helios light client state for hubPoolStore, blockNumber, and slot key isn't
        // equal to passed in slot value.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        // We don't update the helios state client in this test:
        vm.expectRevert(UniversalStorageProof_SpokePool.SlotValueMismatch.selector);
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testIncorrectTarget() public {
        // Reverts if the target is not the zero address or the spoke pool contract
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        // Change target in the slot value:
        bytes memory value = abi.encode(makeAddr("randomTarget"), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectRevert(UniversalStorageProof_SpokePool.NotTarget.selector);
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testAdminRelayMessage() public {
        uint256 latestTimestamp = 100 * adminUpdateBuffer; // Make this much larger than spokePool.ADMIN_UPDATE_BUFFER() otherwise
        // the admin message will be too close to the "latest" helios head timestamp.
        vm.warp(latestTimestamp);

        vm.startPrank(owner);
        // Relay message normally to contract:
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", bytes32("test"), bytes32("test2"))
        );
        spokePool.adminRelayMessage(message);
        vm.stopPrank();
    }

    function testAdminRelayMessage_latestUpdateTooRecent() public {
        uint256 latestTimestamp = 100 * adminUpdateBuffer; // See comment in test above about how to set this.
        vm.warp(latestTimestamp);

        // Update the helios head so its very close or equal to the current latest timestamp.
        helios.updateHeadTimestamp(latestTimestamp);

        vm.startPrank(owner);
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        vm.expectRevert(UniversalStorageProof_SpokePool.AdminUpdateTooCloseToLastHeliosUpdate.selector);
        spokePool.adminRelayMessage(message);
        vm.stopPrank();
    }

    function testAdminRelayMessage_notOwner() public {
        uint256 latestTimestamp = 100 * adminUpdateBuffer; // See comment in test above about how to set this.
        vm.warp(latestTimestamp);

        vm.startPrank(rando);
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        vm.expectRevert();
        spokePool.adminRelayMessage(message);
        vm.stopPrank();
    }

    function testDelegateCall() public {
        // Can call other functions on the contract
        bytes memory message = abi.encodeWithSignature("setCrossDomainAdmin(address)", address(hubPool));
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectCall(address(spokePool), abi.encodeWithSignature("setCrossDomainAdmin(address)", address(hubPool)));
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testBridgeTokensToHubPool_cctp() public {
        // Uses CCTP to send USDC
        assertEq(spokePool.withdrawalRecipient(), hubPool);
        vm.expectCall(
            address(cctpMessenger),
            abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address)",
                usdcMintAmount,
                CircleDomainIds.Ethereum,
                spokePool.withdrawalRecipient(),
                address(usdc)
            )
        );
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, address(usdc));
    }

    function testBridgeTokensToHubPool_default() public {
        // Should revert
        vm.expectRevert();
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, makeAddr("erc20"));
    }

    function testRequireAdminSender() public {
        // Calling onlyCrossDomainAdmin functions directly should revert.
        // Even if we mock the cross domain admin, it won't work as all admin calls must go through
        // some function that has the validateInternalCalls() modifier.
        vm.startPrank(spokePool.crossDomainAdmin());
        vm.expectRevert(UniversalStorageProof_SpokePool.AdminCallNotValidated.selector);
        spokePool.setCrossDomainAdmin(makeAddr("randomAdmin"));
        vm.stopPrank();
    }
}
