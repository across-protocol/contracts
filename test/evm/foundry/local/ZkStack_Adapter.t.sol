// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import { ZkStack_Adapter } from "../../../../contracts/chain-adapters/ZkStack_Adapter.sol";
import { ZkStack_CustomGasToken_Adapter, FunderInterface } from "../../../../contracts/chain-adapters/ZkStack_CustomGasToken_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { MockBridgeHub, BridgeHubInterface } from "../../../../contracts/test/MockZkStackBridgeHub.sol";

// The Hub Pool normally delegatecalls these adapters, and the Hub Pool has a receive() function. Since we are testing these adapters by calling to them
// directly, we need to give them receive() functionality.
contract MockZkStack_Adapter is ZkStack_Adapter {
    constructor(
        uint256 _chainId,
        BridgeHubInterface _bridgeHub,
        WETH9Interface _l1Weth,
        address _l2RefundAddress,
        uint256 _l2GasLimit,
        uint256 _l1GasToL2GasPerPubDataLimit
    ) ZkStack_Adapter(_chainId, _bridgeHub, _l1Weth, _l2RefundAddress, _l2GasLimit, _l1GasToL2GasPerPubDataLimit) {}

    receive() external payable {}
}

contract MockZkStack_CustomGasToken_Adapter is ZkStack_CustomGasToken_Adapter {
    constructor(
        uint256 _chainId,
        BridgeHubInterface _bridgeHub,
        WETH9Interface _l1Weth,
        address _l2RefundAddress,
        FunderInterface _customGasTokenFunder,
        uint256 _l2GasLimit,
        uint256 _l1GasToL2GasPerPubDataLimit
    )
        ZkStack_CustomGasToken_Adapter(
            _chainId,
            _bridgeHub,
            _l1Weth,
            _l2RefundAddress,
            _customGasTokenFunder,
            _l2GasLimit,
            _l1GasToL2GasPerPubDataLimit
        )
    {}

    receive() external payable {}
}

contract MockFunder is FunderInterface {
    function withdraw(IERC20 token, uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

contract ZkStackAdapterTest is Test {
    ZkStack_CustomGasToken_Adapter zksCustomGasAdapter;
    ZkStack_Adapter zksAdapter;

    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    Token_ERC20 l1CustomGasToken;
    Token_ERC20 l2CustomGasToken;
    WETH9 l1Weth;
    WETH9 l2Weth;

    MockBridgeHub bridgeHub;

    address owner;
    address sharedBridge;
    uint256 baseCost;

    uint256 constant ZK_CHAIN_ID = 324;
    uint256 constant ZK_ALT_CHAIN_ID = 323;
    uint256 constant L2_GAS_LIMIT = 200000;
    uint256 constant L2_GAS_PER_PUBDATA_LIMIT = 50000;

    function setUp() public {
        owner = makeAddr("owner");
        sharedBridge = makeAddr("sharedBridge");

        l1Token = new Token_ERC20("l1Token", "l1Token");
        l2Token = new Token_ERC20("l2Token", "l2Token");
        l1CustomGasToken = new Token_ERC20("l1CustomGasToken", "l1CustomGasToken");
        l2CustomGasToken = new Token_ERC20("l2CustomGasToken", "l2CustomGasToken");
        l1Weth = new WETH9();
        l2Weth = new WETH9();

        MockFunder funder = new MockFunder();
        bridgeHub = new MockBridgeHub(sharedBridge);

        bridgeHub.setBaseToken(ZK_ALT_CHAIN_ID, address(l1CustomGasToken));
        baseCost = bridgeHub.l2TransactionBaseCost(0, 0, L2_GAS_LIMIT, L2_GAS_PER_PUBDATA_LIMIT);

        zksAdapter = new MockZkStack_Adapter(
            ZK_CHAIN_ID,
            bridgeHub,
            WETH9Interface(address(l1Weth)),
            owner,
            L2_GAS_LIMIT,
            L2_GAS_PER_PUBDATA_LIMIT
        );

        zksCustomGasAdapter = new MockZkStack_CustomGasToken_Adapter(
            ZK_ALT_CHAIN_ID,
            bridgeHub,
            WETH9Interface(address(l1Weth)),
            owner,
            funder,
            L2_GAS_LIMIT,
            L2_GAS_PER_PUBDATA_LIMIT
        );

        // For the sake of simplicity, give the funder an unlimited amount of tokens.
        l1CustomGasToken.mint(address(funder), type(uint256).max);
    }

    // Native gas token tests:

    // The expected transaction hash should be a hash of information given to the adapter, like the target and message, as well
    // as information defined in the adapter's constructor.
    function testRelayMessage(address target, bytes memory message) public {
        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestDirect({
                    chainId: ZK_CHAIN_ID,
                    mintValue: baseCost,
                    l2Contract: target,
                    l2Value: 0,
                    l2Calldata: message,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    factoryDeps: new bytes[](0),
                    refundRecipient: owner
                })
            )
        );
        vm.expectEmit(address(zksAdapter));
        emit ZkStack_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksAdapter.relayMessage{ value: baseCost }(target, message);
    }

    // Sending Weth should give a hash of L2TransactionHashDirect.
    function testRelayWeth(uint256 amountToSend, address random) public {
        amountToSend = uint256(bound(amountToSend, 1, 2**255)); // Bound the amountToSend so that amountToSend + baseCost <= 2**256-1
        vm.deal(random, amountToSend + baseCost);
        vm.startPrank(random);
        // Normally, the Hub Pool would be delegatecalling the adapter so the balance would "already exist" in the adapter, but here,
        // we are just testing that the adapter is producing the expected calldata, so we must give it sufficient funds to make calls.
        l1Weth.deposit{ value: amountToSend }();
        l1Weth.transfer(address(zksAdapter), amountToSend);

        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestDirect({
                    chainId: ZK_CHAIN_ID,
                    mintValue: baseCost,
                    l2Contract: random,
                    l2Value: 0,
                    l2Calldata: "",
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    factoryDeps: new bytes[](0),
                    refundRecipient: owner
                })
            )
        );

        vm.expectEmit(address(zksAdapter));
        emit ZkStack_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksAdapter.relayTokens{ value: baseCost }(address(l1Weth), address(l2Weth), amountToSend, random);
        vm.stopPrank();
    }

    // Sending any random token should construct a L2TransactionTwoBridges struct.
    function testRelayToken(uint256 amountToSend, address random) public {
        amountToSend = uint256(bound(amountToSend, 1, type(uint256).max));
        l1Token.mint(address(zksAdapter), amountToSend);
        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestTwoBridgesOuter({
                    chainId: ZK_CHAIN_ID,
                    mintValue: baseCost,
                    l2Value: 0,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    refundRecipient: owner,
                    secondBridgeAddress: sharedBridge,
                    secondBridgeValue: 0,
                    secondBridgeCalldata: abi.encode(address(l1Token), amountToSend, random)
                })
            )
        );

        vm.expectEmit(address(zksAdapter));
        emit ZkStack_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksAdapter.relayTokens{ value: baseCost }(address(l1Token), address(l2Token), amountToSend, random);
    }

    // Custom gas token tests:

    // The expected transaction hash should be a hash of information given to the adapter, like the target and message, as well
    // as information defined in the adapter's constructor.
    // There should also be an approval for the base fee amount on the custom gas token contract.
    function testRelayMessageCustomGas(address target, bytes memory message) public {
        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestDirect({
                    chainId: ZK_ALT_CHAIN_ID,
                    mintValue: baseCost,
                    l2Contract: target,
                    l2Value: 0,
                    l2Calldata: message,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    factoryDeps: new bytes[](0),
                    refundRecipient: owner
                })
            )
        );
        vm.expectEmit(address(zksCustomGasAdapter));
        emit ZkStack_CustomGasToken_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksCustomGasAdapter.relayMessage(target, message);
        // Approve only the amount of the fee of the custom gas token. Since we don't actually transferFrom, the approval should stand.
        assertEq(l1CustomGasToken.allowance(address(zksCustomGasAdapter), sharedBridge), baseCost);
    }

    // Sending Weth should be a TwoBridgesOuter struct, should withdraw weth that it owns, and then call the l2 bridge with the token address as address(1).
    function testRelayWethCustomGas(uint256 amountToSend, address random) public {
        vm.deal(random, amountToSend);
        vm.startPrank(random);
        // Normally, the Hub Pool would be delegatecalling the adapter so the balance would "already exist" in the adapter, but here,
        // we are just testing that the adapter is producing the expected calldata, so we must give it sufficient funds to make calls.
        l1Weth.deposit{ value: amountToSend }();
        l1Weth.transfer(address(zksCustomGasAdapter), amountToSend);

        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestTwoBridgesOuter({
                    chainId: ZK_ALT_CHAIN_ID,
                    mintValue: baseCost,
                    l2Value: 0,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    refundRecipient: owner,
                    secondBridgeAddress: sharedBridge,
                    secondBridgeValue: amountToSend,
                    secondBridgeCalldata: abi.encode(address(1), amountToSend, random)
                })
            )
        );

        vm.expectEmit(address(zksCustomGasAdapter));
        emit ZkStack_CustomGasToken_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksCustomGasAdapter.relayTokens(address(l1Weth), address(l2Weth), amountToSend, random);
        vm.stopPrank();
        // Approve only the amount of the fee of the custom gas token. Since we don't actually transferFrom, the approval should stand.
        assertEq(l1CustomGasToken.allowance(address(zksCustomGasAdapter), sharedBridge), baseCost);
    }

    // There should be a hash from L2TransactionTwoBridges, an approval for the fee amount in custom gas token, and an approval for the amount to transfer in
    // the l1 token contract.
    function testRelayTokenCustomGas(uint256 amountToSend, address random) public {
        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestTwoBridgesOuter({
                    chainId: ZK_ALT_CHAIN_ID,
                    mintValue: baseCost,
                    l2Value: 0,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    refundRecipient: owner,
                    secondBridgeAddress: sharedBridge,
                    secondBridgeValue: 0,
                    secondBridgeCalldata: abi.encode(address(l1Token), amountToSend, random)
                })
            )
        );

        vm.expectEmit(address(zksCustomGasAdapter));
        emit ZkStack_CustomGasToken_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksCustomGasAdapter.relayTokens(address(l1Token), address(l2Token), amountToSend, random);
        // Approve only the amount of the fee of the custom gas token. Since we don't actually transferFrom, the approval should stand.
        assertEq(l1CustomGasToken.allowance(address(zksCustomGasAdapter), sharedBridge), baseCost);
        assertEq(l1Token.allowance(address(zksCustomGasAdapter), sharedBridge), amountToSend);
    }

    // There should be a hash of L2TransactionDirect and an approval for the custom gas token.
    function testRelayCustomGasToken(uint256 amountToSend, address random) public {
        amountToSend = uint256(bound(amountToSend, 1, 2**255)); // Bound amountToSend so amountToSend+baseCost < 2**256
        bytes32 expectedTxnHash = keccak256(
            abi.encode(
                BridgeHubInterface.L2TransactionRequestDirect({
                    chainId: ZK_ALT_CHAIN_ID,
                    mintValue: baseCost,
                    l2Contract: random,
                    l2Value: 0,
                    l2Calldata: "",
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA_LIMIT,
                    factoryDeps: new bytes[](0),
                    refundRecipient: owner
                })
            )
        );
        vm.expectEmit(address(zksCustomGasAdapter));
        emit ZkStack_CustomGasToken_Adapter.ZkStackMessageRelayed(expectedTxnHash);
        zksCustomGasAdapter.relayTokens(address(l1CustomGasToken), address(l2CustomGasToken), amountToSend, random);

        // Approve only the amount of the fee of the custom gas token. Since we don't actually transferFrom, the approval should stand.
        assertEq(l1CustomGasToken.allowance(address(zksCustomGasAdapter), sharedBridge), baseCost + amountToSend);
        assertEq(l1Token.allowance(address(zksCustomGasAdapter), sharedBridge), 0);
    }
}
