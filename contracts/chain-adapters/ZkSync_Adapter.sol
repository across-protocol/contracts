// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ZkSyncInterface {
    // _contractL2: L2 address of the contract to be called.
    // _l2Value: Amount of ETH to pass with the call to L2; used as msg.value for the transaction.
    // _calldata: Calldata of the transaction call; encoded the same way as in Ethereum.
    // _l2GasLimit: Gas limit of the L2 transaction call.
    // _l2GasPerPubdataByteLimit: A constant representing how much gas is required to publish a byte of data from
    //  L1 to L2. https://era.zksync.io/docs/api/js/utils.html#gas
    // _factoryDeps: Bytecodes array containing the bytecode of the contract being deployed.
    //  If the contract is a factory contract, the array contains the bytecodes of the contracts it can deploy.
    // _refundRecipient: Address that receives the rest of the fee after the transaction execution.
    //  If refundRecipient == 0, L2 msg.sender is used. Note: If the _refundRecipient is a smart contract,
    //  then during the L1 to L2 transaction its address is aliased.
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 canonicalTxHash);

    // @notice Estimates the cost in Ether of requesting execution of an L2 transaction from L1
    // @param _l1GasPrice Effective gas price on L1 (priority fee + base fee)
    // @param _l2GasLimit Gas limit for the L2 transaction
    // @param _l2GasPerPubdataByteLimit Gas limit for the L2 transaction per byte of pubdata
    // @return The estimated L2 gas for the transaction to be paid
    function l2TransactionBaseCost(
        uint256 _l1GasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);
}

interface ZkBridgeLike {
    // @dev: Use ZkSyncInterface.requestL2Transaction to bridge WETH as ETH to L2.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);
}

// Note: this contract just forwards the calls from the HubPool to ZkSync to avoid limits.
// A modified ZKSync_Adapter should be deployed with this address swapped in for all zkSync addresses.
contract LimitBypassProxy is ZkSyncInterface, ZkBridgeLike {
    using SafeERC20 for IERC20;
    ZkSyncInterface public constant zkSync = ZkSyncInterface(0x32400084C286CF3E17e7B677ea9583e60a000324);
    ZkBridgeLike public constant zkErc20Bridge = ZkBridgeLike(0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063);

    function l2TransactionBaseCost(
        uint256 _l1GasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        return zkSync.l2TransactionBaseCost(_l1GasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 canonicalTxHash) {
        return
            zkSync.requestL2Transaction{ value: msg.value }(
                _contractL2,
                _l2Value,
                _calldata,
                _l2GasLimit,
                _l2GasPerPubdataByteLimit,
                _factoryDeps,
                _refundRecipient
            );
    }

    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash) {
        IERC20(_l1Token).safeIncreaseAllowance(address(zkErc20Bridge), _amount);
        return
            zkErc20Bridge.deposit{ value: msg.value }(
                _l2Receiver,
                _l1Token,
                _amount,
                _l2TxGasLimit,
                _l2TxGasPerPubdataByte,
                _refundRecipient
            );
    }
}

/**
 * @notice Contract containing logic to send messages from L1 to ZkSync.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract ZkSync_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    // We need to pay a base fee to the operator to include our L1 --> L2 transaction.
    // https://era.zksync.io/docs/dev/developer-guides/bridging/l1-l2.html#getting-the-base-cost

    // Generally, the following params are a bit hard to set and may change in the future once ZkSync
    // goes live. For now, we'll hardcode these and use aggressive values to ensure inclusion.

    // Limit on L2 gas to spend.
    uint256 public constant L2_GAS_LIMIT = 2_000_000;

    // How much gas is required to publish a byte of data from L1 to L2. 800 is the required value
    // as set here https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/ethereum/contracts/zksync/facets/Mailbox.sol#L226
    // Note, this value can change and will require an updated adapter.
    uint256 public constant L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT = 800;

    // This address receives any remaining fee after an L1 to L2 transaction completes.
    // If refund recipient = address(0) then L2 msg.sender is used, unless msg.sender is a contract then its address
    // gets aliased.
    address public immutable l2RefundAddress;

    // Hardcode the following ZkSync system contract addresses to save gas on construction. This adapter can be
    // redeployed in the event that the following addresses change.

    // Main contract used to send L1 --> L2 messages. Fetchable via `zks_getMainContract` method on JSON RPC.
    ZkSyncInterface public constant zkSyncMessageBridge = ZkSyncInterface(0x32400084C286CF3E17e7B677ea9583e60a000324);

    // Contract used to send ETH to L2. Note: this is the same address as the main contract, but separated to allow
    // only this contract to be swapped (leaving the main zkSync contract to be used for messaging).
    ZkSyncInterface public constant zkSyncEthBridge = ZkSyncInterface(0x32400084C286CF3E17e7B677ea9583e60a000324);

    // Bridges to send ERC20 and ETH to L2. Fetchable via `zks_getBridgeContracts` method on JSON RPC.
    ZkBridgeLike public constant zkErc20Bridge = ZkBridgeLike(0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063);

    // Set l1Weth at construction time to make testing easier.
    WETH9Interface public immutable l1Weth;

    // The maximum gas price a transaction sent to this adapter may have. This is set to prevent a block producer from setting an artificially high priority fee
    // when calling a hub pool message relay, which would otherwise cause a large amount of ETH to be sent to L2.
    uint256 private immutable MAX_TX_GASPRICE;

    event ZkSyncMessageRelayed(bytes32 canonicalTxHash);
    error TransactionFeeTooHigh();

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l2RefundAddress address that recieves excess gas refunds on L2.
     * @param _maxTxGasPrice The maximum effective gas price any transaction sent to this adapter may have.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _l2RefundAddress,
        uint256 _maxTxGasPrice
    ) {
        l1Weth = _l1Weth;
        l2RefundAddress = _l2RefundAddress;
        MAX_TX_GASPRICE = _maxTxGasPrice;
    }

    /**
     * @notice Send cross-chain message to target on ZkSync.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message, or the message
     * will revert.
     * @param target Contract on L2 that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        // Returns the hash of the requested L2 transaction. This hash can be used to follow the transaction status.
        bytes32 canonicalTxHash = zkSyncMessageBridge.requestL2Transaction{ value: txBaseCost }(
            target,
            // We pass no ETH with the call, otherwise we'd need to add to the txBaseCost this value.
            0,
            message,
            L2_GAS_LIMIT,
            L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
            new bytes[](0),
            l2RefundAddress
        );

        emit MessageRelayed(target, message);
        emit ZkSyncMessageRelayed(canonicalTxHash);
    }

    /**
     * @notice Bridge tokens to ZkSync.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message
     * or the message will revert.
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
        // https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/ethereum/contracts/zksync/facets/Mailbox.sol#L230
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        // If the l1Token is WETH then unwrap it to ETH then send the ETH to the standard bridge along with the base
        // cost. I've tried sending WETH over the erc20Bridge directly but we receive the wrong WETH
        // on the L2 side. So, we need to unwrap the WETH into ETH and then send.
        bytes32 txHash;
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            // We cannot call the standard ERC20 bridge because it disallows ETH deposits.
            txHash = zkSyncEthBridge.requestL2Transaction{ value: txBaseCost + amount }(
                to,
                amount,
                "",
                L2_GAS_LIMIT,
                L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
                new bytes[](0),
                l2RefundAddress
            );
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(zkErc20Bridge), amount);
            txHash = zkErc20Bridge.deposit{ value: txBaseCost }(
                to,
                l1Token,
                amount,
                L2_GAS_LIMIT,
                L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
                l2RefundAddress
            );
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkSyncMessageRelayed(txHash);
    }

    /**
     * @notice Returns required amount of ETH to send a message.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue() public view returns (uint256) {
        // - tx.gasprice returns effective_gas_price. It's also used by Mailbox contract to estimate L2GasPrice
        // so using tx.gasprice should always pass this check that msg.value >= baseCost + _l2Value
        // https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/ethereum/contracts/zksync/facets/Mailbox.sol#L273
        // - priority_fee_per_gas = min(transaction.max_priority_fee_per_gas, transaction.max_fee_per_gas - block.base_fee_per_gas)
        // - effective_gas_price = priority_fee_per_gas + block.base_fee_per_gas
        if (tx.gasprice > MAX_TX_GASPRICE) revert TransactionFeeTooHigh();
        return
            zkSyncMessageBridge.l2TransactionBaseCost(tx.gasprice, L2_GAS_LIMIT, L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT);
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
