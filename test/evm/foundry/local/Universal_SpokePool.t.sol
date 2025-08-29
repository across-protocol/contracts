// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Universal_SpokePool, IHelios } from "../../../../contracts/Universal_SpokePool.sol";
import "../../../../contracts/SpokePool.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import "../../../../contracts/test/MockCCTP.sol";
import { IOFT, SendParam, MessagingFee } from "../../../../contracts/interfaces/IOFT.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { OFTTransportAdapter } from "../../../../contracts/libraries/OFTTransportAdapter.sol";

contract MockHelios is IHelios {
    mapping(bytes32 => bytes32) public storageSlots;

    uint256 public headTimestamp;

    function updateStorageSlot(bytes32 key, bytes32 valueHash) external {
        storageSlots[key] = valueHash;
    }

    function updateHeadTimestamp(uint256 _timestamp) external {
        headTimestamp = _timestamp;
    }

    function getStorageSlot(uint256, address, bytes32 _key) external view returns (bytes32) {
        return storageSlots[_key];
    }
}

contract MockUniversalSpokePool is Universal_SpokePool {
    constructor(
        uint256 _adminUpdateBuffer,
        address _helios,
        address _hubPoolStore,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _oftDstId,
        uint256 _oftFeeCap
    )
        Universal_SpokePool(
            _adminUpdateBuffer,
            _helios,
            _hubPoolStore,
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger,
            _oftDstId,
            _oftFeeCap
        )
    {}

    function test_bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external payable {
        _bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}

contract UniversalSpokePoolTest is Test {
    using AddressToBytes32 for address;
    MockUniversalSpokePool spokePool;
    MockHelios helios;

    address hubPoolStore;
    address hubPool;
    uint256 nonce = 0;
    address owner;
    address rando;
    uint256 adminUpdateBuffer = 1 days;

    ERC20 usdc;
    ERC20 usdt;
    uint256 usdcMintAmount = 100e6;
    MockCCTPMessenger cctpMessenger;
    uint256 oftDstEid = 1;

    function setUp() public {
        helios = new MockHelios();
        usdc = new ERC20("USDC", "USDC");
        usdt = new ERC20("USDT", "USDT");
        MockCCTPMinter minter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(ITokenMinter(minter));
        hubPool = makeAddr("hubPool");
        owner = vm.addr(1);
        rando = vm.addr(2);
        spokePool = new MockUniversalSpokePool(
            adminUpdateBuffer,
            address(helios),
            hubPoolStore,
            address(0),
            7200,
            7200,
            IERC20(address(usdc)),
            ITokenMessenger(address(cctpMessenger)),
            uint32(oftDstEid),
            1e18
        );
        vm.prank(owner);
        address proxy = address(
            new ERC1967Proxy(address(spokePool), abi.encodeCall(Universal_SpokePool.initialize, (0, hubPool, hubPool)))
        );
        spokePool = MockUniversalSpokePool(payable(proxy));
        deal(address(usdc), address(spokePool), usdcMintAmount, true);
    }

    function testExecuteMessage() public {
        // Should be able to call relayRootBundle
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.executeMessage(nonce, value, 100);
    }

    function testExecuteMessage_addressZeroTarget() public {
        // Should be able to call relayRootBundle with slot value target set to zero address
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        bytes memory value = abi.encode(address(0), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.executeMessage(nonce, value, 100);
    }

    function testReplayProtection() public {
        // Should not be able to receive same L1 state twice, even if block number changes.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        vm.expectRevert(Universal_SpokePool.AlreadyExecuted.selector);
        spokePool.executeMessage(nonce, value, 101); // block number changes doesn't impact replay protection
    }

    function testExecutedMessages() public {
        // Checks replay protection mapping is updated as expected.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        assertFalse(spokePool.executedMessages(nonce));
        spokePool.executeMessage(nonce, value, 100);
        assertTrue(spokePool.executedMessages(nonce));
    }

    function testHeliosMissingState() public {
        // Reverts if helios light client state for hubPoolStore, blockNumber, and slot key isn't
        // equal to passed in slot value.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes memory value = abi.encode(address(spokePool), message);
        // We don't update the helios state client in this test:
        vm.expectRevert(Universal_SpokePool.SlotValueMismatch.selector);
        spokePool.executeMessage(nonce, value, 100);
    }

    function testIncorrectTarget() public {
        // Reverts if the target is not the zero address or the spoke pool contract
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        // Change target in the slot value:
        bytes memory value = abi.encode(makeAddr("randomTarget"), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        vm.expectRevert(Universal_SpokePool.NotTarget.selector);
        spokePool.executeMessage(nonce, value, 100);
    }

    function testAdminExecuteMessage() public {
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
        spokePool.adminExecuteMessage(message);
        vm.stopPrank();
    }

    function testAdminExecuteMessage_latestUpdateTooRecent() public {
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
        vm.expectRevert(Universal_SpokePool.AdminUpdateTooCloseToLastHeliosUpdate.selector);
        spokePool.adminExecuteMessage(message);
        vm.stopPrank();
    }

    function testAdminExecuteMessage_notOwner() public {
        uint256 latestTimestamp = 100 * adminUpdateBuffer; // See comment in test above about how to set this.
        vm.warp(latestTimestamp);

        vm.startPrank(rando);
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        vm.expectRevert();
        spokePool.adminExecuteMessage(message);
        vm.stopPrank();
    }

    function testDelegateCall() public {
        // Can call other functions on the contract
        bytes memory message = abi.encodeWithSignature("setCrossDomainAdmin(address)", address(hubPool));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        vm.expectCall(address(spokePool), abi.encodeWithSignature("setCrossDomainAdmin(address)", address(hubPool)));
        spokePool.executeMessage(nonce, value, 100);
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
        vm.expectRevert(Universal_SpokePool.AdminCallNotValidated.selector);
        spokePool.setCrossDomainAdmin(makeAddr("randomAdmin"));
        vm.stopPrank();
    }

    function testSetOftMessenger() public {
        IOFT oftMessenger = IOFT(new MockOFTMessenger(address(usdt)));
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        assertEq(spokePool.oftMessengers(address(usdt)), address(oftMessenger));
    }

    function testSetOftMessenger_removeMessenger() public {
        IOFT oftMessenger = IOFT(new MockOFTMessenger(address(usdt)));
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        assertEq(spokePool.oftMessengers(address(usdt)), address(oftMessenger));

        nonce++;

        // Remove the messenger by setting to address(0)
        message = abi.encodeWithSignature("setOftMessenger(address,address)", address(usdt), address(0));
        value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        assertEq(spokePool.oftMessengers(address(usdt)), address(0));
    }

    function testNonZeroLzFee() public {
        // Mock an OFT messenger that returns a non-zero lzTokenFee
        MockOFTMessenger oftMessengerWithNonZeroLzFee = new MockOFTMessenger(address(usdt));
        oftMessengerWithNonZeroLzFee.setFeesToReturn(0, 1); // nativeFee = 0, lzFee = 1

        // Set this messenger for USDT
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessengerWithNonZeroLzFee)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        nonce++; // Increment nonce for the next message

        // Expect the OftLzFeeNotZero error from OFTTransportAdapter
        vm.expectRevert(OFTTransportAdapter.OftLzFeeNotZero.selector);
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, address(usdt));
    }

    function testFeeTooHigh() public {
        // Mock an OFT messenger that returns a nativeFee higher than OFT_FEE_CAP
        uint256 highNativeFee = spokePool.OFT_FEE_CAP() + 1;
        MockOFTMessenger oftMessengerWithHighFee = new MockOFTMessenger(address(usdt));
        oftMessengerWithHighFee.setFeesToReturn(highNativeFee, 0); // nativeFee > OFT_FEE_CAP, lzFee = 0

        // Set this messenger for USDT
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessengerWithHighFee)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        nonce++; // Increment nonce for the next message

        // Expect the OftFeeCapExceeded error from OFTTransportAdapter.
        // Provide msg.value to cover the quoted fee so the cap guard is triggered.
        vm.expectRevert(OFTTransportAdapter.OftFeeCapExceeded.selector);
        spokePool.test_bridgeTokensToHubPool{ value: highNativeFee }(usdcMintAmount, address(usdt));
    }

    function testBridgeTokensToHubPool_oft() public {
        IOFT oftMessenger = IOFT(new MockOFTMessenger(address(usdt)));
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);

        vm.expectCall(
            address(oftMessenger),
            abi.encodeCall(
                oftMessenger.send,
                (
                    SendParam({
                        dstEid: uint32(oftDstEid),
                        to: hubPool.toBytes32(),
                        amountLD: usdcMintAmount,
                        minAmountLD: usdcMintAmount,
                        extraOptions: bytes(""),
                        composeMsg: bytes(""),
                        oftCmd: bytes("")
                    }),
                    MessagingFee({ nativeFee: 0, lzTokenFee: 0 }),
                    address(spokePool)
                )
            )
        );
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, address(usdt));
    }

    function testBridgeTokensToHubPool_oft_insufficientBalanceForFee() public {
        uint256 nativeFee = 1e17; // Less than OFT_FEE_CAP
        MockOFTMessenger oftMessenger = new MockOFTMessenger(address(usdt));
        oftMessenger.setFeesToReturn(nativeFee, 0);

        // Set this messenger for USDT
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        nonce++;

        // Expect revert due to caller underpaying the required OFT native fee
        vm.expectRevert(SpokePool.OFTFeeUnderpaid.selector);
        spokePool.test_bridgeTokensToHubPool{ value: nativeFee - 1 }(usdcMintAmount, address(usdt));
    }

    function testBridgeTokensToHubPool_oft_incorrectAmountReceived() public {
        MockOFTMessenger oftMessenger = new MockOFTMessenger(address(usdt));

        // Set this messenger for USDT
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        nonce++;

        // Set amountReceivedLD to be different from the sent amount
        oftMessenger.setLDAmountsToReturn(usdcMintAmount, usdcMintAmount - 1);

        // Expect revert due to incorrect amount received
        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountReceivedLD.selector);
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, address(usdt));
    }

    function testBridgeTokensToHubPool_oft_incorrectAmountSent() public {
        MockOFTMessenger oftMessenger = new MockOFTMessenger(address(usdt));

        // Set this messenger for USDT
        bytes memory message = abi.encodeWithSignature(
            "setOftMessenger(address,address)",
            address(usdt),
            address(oftMessenger)
        );
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(spokePool.getSlotKey(nonce), keccak256(value));
        spokePool.executeMessage(nonce, value, 100);
        nonce++;

        // Set amountSentLD to be different from the sent amount
        oftMessenger.setLDAmountsToReturn(usdcMintAmount - 1, usdcMintAmount);

        // Expect revert due to incorrect amount sent
        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountSentLD.selector);
        spokePool.test_bridgeTokensToHubPool(usdcMintAmount, address(usdt));
    }
}
