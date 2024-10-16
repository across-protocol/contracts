// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title BridgeHubInterface
 * @notice This interface is shared between ZkStack adapters. It is the main interaction point for bridging to ZkStack chains.
 */
interface BridgeHubInterface {
    struct L2TransactionRequestDirect {
        uint256 chainId;
        uint256 mintValue;
        address l2Contract;
        uint256 l2Value;
        bytes l2Calldata;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdataByteLimit;
        bytes[] factoryDeps;
        address refundRecipient;
    }

    /**
     * @notice the mailbox is called directly after the sharedBridge received the deposit.
     * This assumes that either ether is the base token or the msg.sender has approved mintValue allowance for the
     * sharedBridge. This means this is not ideal for contract calls, as the contract would have to handle token
     * allowance of the base Token.
     * @param _request the direct request.
     */
    function requestL2TransactionDirect(L2TransactionRequestDirect calldata _request)
        external
        payable
        returns (bytes32 canonicalTxHash);

    struct L2TransactionRequestTwoBridgesOuter {
        uint256 chainId;
        uint256 mintValue;
        uint256 l2Value;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdataByteLimit;
        address refundRecipient;
        address secondBridgeAddress;
        uint256 secondBridgeValue;
        bytes secondBridgeCalldata;
    }

    /**
     * @notice After depositing funds to the sharedBridge, the secondBridge is called to return the actual L2 message
     * which is sent to the Mailbox. This assumes that either ether is the base token or the msg.sender has approved
     * the sharedBridge with the mintValue, and also the necessary approvals are given for the second bridge. The logic
     * of this bridge is to allow easy depositing for bridges. Each contract that handles the users ERC20 tokens needs
     * approvals from the user, this contract allows the user to approve for each token only its respective bridge.
     * This function is great for contract calls to L2, the secondBridge can be any contract.
     * @param _request the two bridges request.
     */
    function requestL2TransactionTwoBridges(L2TransactionRequestTwoBridgesOuter calldata _request)
        external
        payable
        returns (bytes32 canonicalTxHash);

    /**
     * @notice Gets the shared bridge.
     * @dev The shared bridge manages ERC20 tokens.
     */
    function sharedBridge() external view returns (address);

    /**
     * @notice Gets the base token for a chain.
     * @dev Base token == native token.
     */
    function baseToken(uint256 _chainId) external view returns (address);

    /**
     * @notice Computes the base transaction cost for a transaction.
     * @param _chainId the chain the transaction is being sent to.
     * @param _gasPrice the l1 gas price at time of execution.
     * @param _l2GasLimit the gas limit for the l2 transaction.
     * @param _l2GasPerPubdataByteLimit configuration value that changes infrequently.
     */
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);
}
