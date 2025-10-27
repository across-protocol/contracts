// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";

import { Universal_Adapter } from "../../../../contracts/chain-adapters/Universal_Adapter.sol";
import { AdapterStore, MessengerTypes } from "../../../../contracts/AdapterStore.sol";
import { HubPoolStore } from "../../../../contracts/chain-adapters/utilities/HubPoolStore.sol";
import { IOFT, SendParam, MessagingFee } from "../../../../contracts/interfaces/IOFT.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

// A mock contract to simulate the HubPool's delegatecall to the Universal_Adapter
contract MockHub {
    address public immutable adapter;

    constructor(address _adapter) {
        adapter = _adapter;
    }

    function callRelayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable {
        // This simulates HubPool's delegatecall to the adapter
        (bool success, ) = adapter.delegatecall(
            abi.encodeWithSignature("relayTokens(address,address,uint256,address)", l1Token, l2Token, amount, to)
        );
        require(success, "delegatecall failed");
    }

    // fallback/receive to accept ETH funding
    fallback() external payable {}

    receive() external payable {}
}

contract UniversalAdapterOFTTest is Test {
    using SafeERC20 for IERC20;

    // Mainnet Addresses
    address constant USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant OFT_MESSENGER_ETH_TO_ARB = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant OPTIMISM_GATEWAY = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1; // A known large USDT holder

    // Test contracts
    Universal_Adapter universalAdapter;
    AdapterStore adapterStore;
    HubPoolStore hubPoolStore;
    MockHub mockHub;

    // Interfaces
    IERC20 usdt;
    IOFT oftMessenger;

    // Test parameters
    uint256 forkId;
    uint256 constant SEND_AMOUNT = 1 * 10**6; // 1 USDT (6 decimals)
    uint256 constant ETH_FUNDING = 0.1 ether;
    uint32 constant DST_EID = 30110; // Arbitrum EID
    address constant RECIPIENT = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D; // dev wallet

    function setUp() public {
        // 1. Create and select a mainnet fork
        string memory nodeUrl = vm.envString("NODE_URL_1");
        require(bytes(nodeUrl).length > 0, "NODE_URL_1 env var not set");
        forkId = vm.createFork(nodeUrl);
        vm.selectFork(forkId);

        // 2. Deploy necessary contracts
        adapterStore = new AdapterStore();
        // HubPoolStore needs a hubPool address, we can use a mock address
        hubPoolStore = new HubPoolStore(address(0x123));
        universalAdapter = new Universal_Adapter(
            hubPoolStore,
            IERC20(USDC_ADDRESS),
            ITokenMessenger(address(0)), // CCTP not tested here
            0, // CCTP not tested here
            address(adapterStore),
            DST_EID,
            1 ether // oftFeeCap
        );

        // 3. Deploy the MockHub which will delegatecall to the adapter
        mockHub = new MockHub(address(universalAdapter));

        // 4. Instantiate interfaces for on-chain contracts
        usdt = IERC20(USDT_ADDRESS);
        oftMessenger = IOFT(OFT_MESSENGER_ETH_TO_ARB);
    }

    function test_RelayTokensViaOFT() public {
        // --- Setup ---
        // 1. Set the OFT messenger for USDT in the AdapterStore
        // The owner of AdapterStore is the deployer, which is this test contract.
        adapterStore.setMessenger(MessengerTypes.OFT_MESSENGER, DST_EID, USDT_ADDRESS, OFT_MESSENGER_ETH_TO_ARB);
        // 2. Fund MockHub with ETH and USDT
        vm.deal(address(mockHub), ETH_FUNDING);

        vm.startPrank(OPTIMISM_GATEWAY);
        usdt.safeTransfer(address(mockHub), SEND_AMOUNT);
        vm.stopPrank();

        assertEq(address(mockHub).balance, ETH_FUNDING, "MockHub ETH balance is incorrect");
        assertEq(usdt.balanceOf(address(mockHub)), SEND_AMOUNT, "MockHub USDT balance is incorrect");
        // 3. Get the expected messaging fee by calling the real messenger's view function
        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(RECIPIENT))),
            amountLD: SEND_AMOUNT,
            minAmountLD: SEND_AMOUNT,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        MessagingFee memory fee = oftMessenger.quoteSend(sendParam, false);
        uint256 nativeFee = fee.nativeFee;
        // Ensure we have enough ETH for the fee
        require(ETH_FUNDING >= nativeFee, "ETH_FUNDING is less than required nativeFee");
        // --- Expectations ---
        // We expect the Universal_Adapter (via MockHub's delegatecall) to:
        // 1. Approve the OFT messenger to spend USDT
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(address(mockHub), OFT_MESSENGER_ETH_TO_ARB, SEND_AMOUNT);
        // 2. Call the `send` function on the OFT messenger with the correct parameters and native fee
        vm.expectCall(
            OFT_MESSENGER_ETH_TO_ARB,
            nativeFee, // msg.value
            abi.encodeCall(oftMessenger.send, (sendParam, fee, address(mockHub)))
        );

        // Call the adapter's relayTokens via the MockHub.
        mockHub.callRelayTokens(USDT_ADDRESS, address(0), SEND_AMOUNT, RECIPIENT);

        // Verify that USDT was transferred from the mock hub and the correct amount of ETH fees was used as nativeFee
        assertEq(usdt.balanceOf(address(mockHub)), 0, "MockHub should have no USDT left");
        assertEq(address(mockHub).balance, ETH_FUNDING - nativeFee, "MockHub should have spent ETH on fees");
    }
}
