// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ZkSyncInterface {
    /// @notice Request execution of L2 transaction from L1.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Value `msg.value` of L2 transaction
    /// @param _calldata The input of the L2 transaction
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount L2 gas that the operator may charge the user for.
    /// @param _factoryDeps An array of L2 bytecodes that will be marked as known on L2
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction. If the transaction fails,
    /// it will also be the address to receive `_l2Value`.
    /// @return txHash The hash of the requested L2 transaction. This hash can be used to follow the transaction status
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);
}

interface ZkBridgeLike {
    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return txHash The L2 transaction hash of deposit finalization
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 txHash);

    /// @return The L2 token address that would be minted for deposit of the given L1 token
    function l2TokenAddress(address _l1Token) external view returns (address);
}

/**
 * @notice Contract containing logic to send messages from L1 to ZkSync.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract ZkSync_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    // We need to pay a base fee to the operator to include our L1 --> L2 transaction.
    // https://era.zksync.io/docs/dev/developer-guides/bridging/l1-l2.html#getting-the-base-cost

    // Generally, the gasLimit and l2GasPrice params are a bit hard to set and may change in the future once ZkSync
    // goes live. For now, we'll hardcode these and use aggressive values to ensure inclusion.
    uint256 public immutable l2GasPrice = 5e9;

    uint32 public immutable gasLimit = 300_000;

    // The large L2 gas per pubdata to sign. This gas is enough to ensure that
    // any reasonable limit will be accepted. Note, that the operator is NOT required to
    // use the honest value of gas per pubdata and it can use any value up to the one signed by the user.
    // In the future releases, we will provide a way to estimate the current gasPerPubdata.
    uint32 DEFAULT_GAS_PER_PUBDATA_LIMIT = 50_000;

    address public constant l2RefundAddress = 0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010;

    // TODO: Change following addresses for Mainnet
    // Hardcode WETH address for L1 since it will not change:
    WETH9Interface public immutable l1Weth = WETH9Interface(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    // Hardcode the following ZkSync system contract addresses to save gas on construction. This adapter can be
    // redeployed in the event that the following addresses change.

    // Main contract used to send L1 --> L2 messages. Fetchable via `zks_getMainContract` method on JSON RPC.
    ZkSyncInterface public immutable zkSync = ZkSyncInterface(0x1908e2BF4a88F91E4eF0DC72f02b8Ea36BEa2319);
    // Bridges to send ERC20 and ETH to L2. Fetchable via `zks_getBridgeContracts` method on JSON RPC.
    ZkBridgeLike public immutable zkErc20Bridge = ZkBridgeLike(0x927DdFcc55164a59E0F33918D13a2D559bC10ce7);
    ZkBridgeLike public immutable zkEthBridge = ZkBridgeLike(0xcbebcD41CeaBBC85Da9bb67527F58d69aD4DfFf5);

    event ZkSyncMessageRelayed(bytes32 txHash);

    /**
     * @notice Send cross-chain message to target on ZkSync.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message, or the message
     * will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        bytes32 txHash = zkSync.requestL2Transaction{ value: txBaseCost }(
            target,
            // We pass no ETH with the call
            0,
            message,
            gasLimit,
            DEFAULT_GAS_PER_PUBDATA_LIMIT,
            new bytes[](0),
            l2RefundAddress
        );

        // A successful L1 -> L2 message produces an L2Log with key = l2TxHash, and value = bytes32(1)
        // whereas a failed L1 -> L2 message produces an L2Log with key = l2TxHash, and value = bytes32(0).

        emit MessageRelayed(target, message);
        emit ZkSyncMessageRelayed(txHash);
    }

    /**
     * @notice Bridge tokens to ZkSync.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message
     * or the message will get stuck.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token, // l2Token is unused.
        uint256 amount,
        address to
    ) external payable override {
        // This could revert if the relay amount is over the ZkSync deposit
        // limit: https://github.com/matter-labs/era-contracts/blob/main/ethereum/contracts/common/AllowList.sol#L150
        // We should make sure that the limit is either set very high or we need to do logic
        // that splits the amount to deposit into multiple chunks. We can't have
        // this function revert or the HubPool will not be able to proceed to the
        // next bundle. See more here:
        // https://github.com/matter-labs/era-contracts/blob/main/docs/Overview.md#deposit-limitation
        // require(zkErc20Bridge.l2TokenAddress(l1Token) == l2Token, "incorrect l2Token address");
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        // If the l1Token is WETH then unwrap it to ETH then send the ETH to the standard bridge along with the base
        // cost.
        bytes32 txHash;
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            // We cannot call the standard ERC20 bridge because
            // it disallows ETH deposits.
            txHash = zkSync.requestL2Transaction{ value: txBaseCost + amount }(
                to,
                amount,
                "0x",
                gasLimit,
                DEFAULT_GAS_PER_PUBDATA_LIMIT,
                new bytes[](0),
                l2RefundAddress
            );

            /**
                A successful L1 -> L2 message produces an L2Log with 
                key = l2TxHash, and value = bytes32(1) whereas a failed L1 -> L2 message produces an L2Log with 
                key = l2TxHash, and value = bytes32(0). 
            */
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(zkErc20Bridge), amount);
            txHash = zkErc20Bridge.deposit{ value: txBaseCost }(
                to,
                l1Token,
                amount,
                gasLimit,
                DEFAULT_GAS_PER_PUBDATA_LIMIT
            );
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkSyncMessageRelayed(txHash);
    }

    /**
     * @notice Returns required amount of ETH to send a message.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue() public pure returns (uint256) {
        return l2GasPrice * gasLimit;
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
