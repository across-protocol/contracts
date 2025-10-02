// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ZkSync_SpokePool, ZkBridgeLike, IERC20, ITokenMessenger } from "../../../../contracts/ZkSync_SpokePool.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../contracts/libraries/AddressConverters.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";

// Simple mock contracts for testing
contract SimpleContract {
    function doNothing() external pure returns (uint256) {
        return 42;
    }
}

// Extension of ZkSync_SpokePool to expose internal functions for testing
contract TestableMockSpokePool is ZkSync_SpokePool {
    constructor(
        address _wrappedNativeTokenAddress
    )
        ZkSync_SpokePool(
            _wrappedNativeTokenAddress,
            IERC20(address(0)),
            ZkBridgeLike(address(0)),
            ITokenMessenger(address(0)),
            1 hours,
            9 hours
        )
    {}

    function test_unwrapwrappedNativeTokenTo(address payable to, uint256 amount) external {
        _unwrapwrappedNativeTokenTo(to, amount);
    }

    function test_is7702DelegatedWallet(address account) external view returns (bool) {
        return _is7702DelegatedWallet(account);
    }

    function test_fillRelayV3(V3RelayExecutionParams memory relayExecution, bytes32 relayer, bool isSlowFill) external {
        _fillRelayV3(relayExecution, relayer, isSlowFill);
    }
}

/**
 * @title SpokePool EIP-7702 Delegation Tests
 * @notice Tests EIP-7702 delegation functionality in SpokePool contract
 */
contract SpokePoolEIP7702Test is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    TestableMockSpokePool spokePool;
    WETH9 weth;

    address owner;
    address relayer;
    address recipient;

    uint256 constant WETH_AMOUNT = 1 ether;
    uint256 constant CHAIN_ID = 1;
    address mockImplementation;

    function setUp() public {
        weth = new WETH9();
        owner = vm.addr(1);
        relayer = vm.addr(2);
        recipient = makeAddr("recipient");
        mockImplementation = makeAddr("mockImplementation");

        // Deploy SpokePool
        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new TestableMockSpokePool(address(weth))),
            abi.encodeCall(ZkSync_SpokePool.initialize, (0, ZkBridgeLike(address(0)), owner, makeAddr("hubPool")))
        );
        spokePool = TestableMockSpokePool(payable(proxy));
        vm.stopPrank();

        // Fund contracts and accounts
        // First give SpokePool some ETH, then deposit it as WETH
        deal(address(spokePool), WETH_AMOUNT * 10);
        vm.prank(address(spokePool));
        weth.deposit{ value: WETH_AMOUNT * 5 }(); // Deposit some of the ETH as WETH for testing

        deal(relayer, 10 ether);
        deal(recipient, 1 ether);
    }

    /**
     * @dev Creates a test contract to simulate EIP-7702 delegated wallet
     * EIP-7702 delegation code must be exactly 23 bytes: 0xef0100 + 20-byte address
     */
    function createMockDelegatedWallet() internal returns (address) {
        // Create bytecode that starts with EIP-7702 prefix (0xef0100) followed by implementation address
        // This creates exactly 23 bytes: 3 bytes prefix + 20 bytes address = 23 bytes
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), mockImplementation);

        address delegatedWallet = makeAddr("delegatedWallet");
        vm.etch(delegatedWallet, delegationCode);
        return delegatedWallet;
    }

    /**
     * @dev Creates a regular contract (not delegated)
     */
    function createRegularContract() internal returns (address) {
        SimpleContract regularContract = new SimpleContract();
        return address(regularContract);
    }

    // Test 1: Verify _is7702DelegatedWallet returns false for EIP-7702 delegated wallets and EOA
    function test_is7702DelegatedWallet_ReturnsFalseForDelegatedWallet() public {
        address delegatedWallet = createMockDelegatedWallet();
        address regularContract = createRegularContract();
        address eoa = makeAddr("eoa");

        //
        assertFalse(
            spokePool.test_is7702DelegatedWallet(delegatedWallet),
            "Should not detect EIP-7702 delegated wallet"
        );
        assertFalse(
            spokePool.test_is7702DelegatedWallet(regularContract),
            "Should not detect regular contract as delegated"
        );
        assertFalse(spokePool.test_is7702DelegatedWallet(eoa), "Should not detect EOA as delegated");
    }

    // Test 2: Verify _unwrapwrappedNativeTokenTo sends WETH to regular contracts
    function test_unwrapToRegularContract() public {
        address regularContract = createRegularContract();
        uint256 initialEthBalance = regularContract.balance;
        uint256 initialWethBalance = weth.balanceOf(regularContract);

        // Sending to regular contract
        spokePool.test_unwrapwrappedNativeTokenTo(payable(regularContract), WETH_AMOUNT);

        // Should receive WETH, not ETH
        assertEq(regularContract.balance, initialEthBalance, "Regular contract should not receive ETH");
        assertEq(
            weth.balanceOf(regularContract),
            initialWethBalance + WETH_AMOUNT,
            "Regular contract should receive WETH"
        );
    }

    // Test 3: Verify _unwrapwrappedNativeTokenTo sends ETH to EOAs
    function test_unwrapToEOA() public {
        address eoa = makeAddr("eoa");
        uint256 initialBalance = eoa.balance;

        // Send to EOA
        spokePool.test_unwrapwrappedNativeTokenTo(payable(eoa), WETH_AMOUNT);

        // Should receive ETH, not WETH
        assertEq(eoa.balance, initialBalance + WETH_AMOUNT, "EOA should receive ETH");
        assertEq(weth.balanceOf(eoa), 0, "EOA should not receive WETH");
    }

    // Test 4: Test the functionality in context of fill relay operations with mock delegated wallet
    // should not receive ETH from fill
    function test_fillRelayWithDelegatedRecipient() public {
        // Create a mock delegated wallet for the recipient
        address delegatedRecipient = createMockDelegatedWallet();
        deal(delegatedRecipient, 1 ether); // Give it some initial ETH

        uint256 initialEthBalance = delegatedRecipient.balance;
        uint256 fillAmount = 0.5 ether;

        // Setup a mock relay with delegated recipient
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = V3SpokePoolInterface
            .V3RelayExecutionParams({
                relay: V3SpokePoolInterface.V3RelayData({
                    depositor: relayer.toBytes32(),
                    recipient: delegatedRecipient.toBytes32(),
                    exclusiveRelayer: bytes32(0),
                    inputToken: address(weth).toBytes32(),
                    outputToken: address(weth).toBytes32(),
                    inputAmount: fillAmount,
                    outputAmount: fillAmount,
                    originChainId: CHAIN_ID,
                    depositId: 1,
                    fillDeadline: uint32(block.timestamp + 1 hours),
                    exclusivityDeadline: 0,
                    message: ""
                }),
                relayHash: keccak256("test"),
                updatedOutputAmount: fillAmount,
                updatedRecipient: delegatedRecipient.toBytes32(),
                updatedMessage: "",
                repaymentChainId: CHAIN_ID
            });

        // Fund the SpokePool with WETH for the slow fill
        deal(address(weth), address(spokePool), fillAmount);

        // Execute the fill
        vm.startPrank(relayer);
        spokePool.test_fillRelayV3(relayExecution, relayer.toBytes32(), true);
        vm.stopPrank();

        // Verify delegated recipient received ETH
        assertEq(delegatedRecipient.balance, initialEthBalance, "Delegated recipient should not receive ETH from fill");
        assertEq(weth.balanceOf(delegatedRecipient), 0.5 ether, "Delegated recipient should receive WETH");
    }
}
