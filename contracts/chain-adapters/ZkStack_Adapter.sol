// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { BridgeHubInterface } from "../interfaces/ZkStackBridgeHub.sol";

/**
 * @notice Contract containing logic to send messages from L1 to ZkStack with ETH as the gas token.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract ZkStack_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    // The ZkSync bridgehub contract treats address(1) to represent ETH.
    address private constant ETH_TOKEN_ADDRESS = address(1);

    // We need to pay a base fee to the operator to include our L1 --> L2 transaction.
    // https://docs.zksync.io/build/developer-reference/l1-l2-interoperability#l1-to-l2-gas-estimation-for-transactions

    // Limit on L2 gas to spend.
    uint256 public immutable L2_GAS_LIMIT; // typically 2_000_000

    // How much gas is required to publish a byte of data from L1 to L2. 800 is the required value
    // as set here https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/ethereum/contracts/zksync/facets/Mailbox.sol#L226
    // Note, this value can change and will require an updated adapter.
    uint256 public immutable L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT; // Typically 800

    // This address receives any remaining fee after an L1 to L2 transaction completes.
    // If refund recipient = address(0) then L2 msg.sender is used, unless msg.sender is a contract then its address
    // gets aliased.
    address public immutable L2_REFUND_ADDRESS;

    // L2 chain id
    uint256 public immutable CHAIN_ID;

    // BridgeHub address
    BridgeHubInterface public immutable BRIDGE_HUB;

    // Set l1Weth at construction time to make testing easier.
    WETH9Interface public immutable L1_WETH;

    // SharedBridge address, which is read from the BridgeHub at construction.
    address public immutable SHARED_BRIDGE;

    // The maximum gas price a transaction sent to this adapter may have. This is set to prevent a block producer from setting an artificially high priority fee
    // when calling a hub pool message relay, which would otherwise cause a large amount of ETH to be sent to L2.
    uint256 private immutable MAX_TX_GASPRICE;

    event ZkStackMessageRelayed(bytes32 indexed canonicalTxHash);

    error ETHGasTokenRequired();
    error TransactionFeeTooHigh();

    /**
     * @notice Constructs new Adapter.
     * @param _chainId The target ZkStack network's chain ID.
     * @param _bridgeHub The bridge hub contract address for the ZkStack network.
     * @param _l1Weth WETH address on L1.
     * @param _l2RefundAddress address that recieves excess gas refunds on L2.
     * @param _l2GasLimit The maximum amount of gas this contract is willing to pay to execute a transaction on L2.
     * @param _l1GasToL2GasPerPubDataLimit The exchange rate of l1 gas to l2 gas.
     * @param _maxTxGasprice The maximum effective gas price any transaction sent to this adapter may have.
     */
    constructor(
        uint256 _chainId,
        BridgeHubInterface _bridgeHub,
        WETH9Interface _l1Weth,
        address _l2RefundAddress,
        uint256 _l2GasLimit,
        uint256 _l1GasToL2GasPerPubDataLimit,
        uint256 _maxTxGasprice
    ) {
        CHAIN_ID = _chainId;
        BRIDGE_HUB = _bridgeHub;
        L1_WETH = _l1Weth;
        L2_REFUND_ADDRESS = _l2RefundAddress;
        L2_GAS_LIMIT = _l2GasLimit;
        MAX_TX_GASPRICE = _maxTxGasprice;
        L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT = _l1GasToL2GasPerPubDataLimit;
        SHARED_BRIDGE = BRIDGE_HUB.sharedBridge();
        address gasToken = BRIDGE_HUB.baseToken(CHAIN_ID);
        if (gasToken != ETH_TOKEN_ADDRESS) {
            revert ETHGasTokenRequired();
        }
    }

    /**
     * @notice Send cross-chain message to target on ZkStack.
     * @dev The HubPool must hold enough ETH to pay for the L2 txn.
     * @param target Contract on L2 that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        uint256 txBaseCost = _computeETHTxCost(L2_GAS_LIMIT);

        // Returns the hash of the requested L2 transaction. This hash can be used to follow the transaction status.
        bytes32 canonicalTxHash = BRIDGE_HUB.requestL2TransactionDirect{ value: txBaseCost }(
            BridgeHubInterface.L2TransactionRequestDirect({
                chainId: CHAIN_ID,
                mintValue: txBaseCost,
                l2Contract: target,
                l2Value: 0,
                l2Calldata: message,
                l2GasLimit: L2_GAS_LIMIT,
                l2GasPerPubdataByteLimit: L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
                factoryDeps: new bytes[](0),
                refundRecipient: L2_REFUND_ADDRESS
            })
        );

        emit MessageRelayed(target, message);
        emit ZkStackMessageRelayed(canonicalTxHash);
    }

    /**
     * @notice Bridge tokens to ZkStack.
     * @dev The HubPool must hold enough ETH to pay for the L2 txn.
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
        // A bypass proxy seems to no longer be needed to avoid deposit limits. The tracking of these limits seems to be deprecated.
        // See: https://github.com/matter-labs/era-contracts/blob/bce4b2d0f34bd87f1aaadd291772935afb1c3bd6/l1-contracts/contracts/bridge/L1ERC20Bridge.sol#L54-L55
        uint256 txBaseCost = _computeETHTxCost(L2_GAS_LIMIT);

        bytes32 txHash;
        if (l1Token == address(L1_WETH)) {
            // If the l1Token is WETH then unwrap it to ETH then send the ETH to the standard bridge along with the base
            // cost.
            L1_WETH.withdraw(amount);
            txHash = BRIDGE_HUB.requestL2TransactionDirect{ value: amount + txBaseCost }(
                BridgeHubInterface.L2TransactionRequestDirect({
                    chainId: CHAIN_ID,
                    mintValue: txBaseCost + amount,
                    l2Contract: to,
                    l2Value: amount,
                    l2Calldata: "",
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
                    factoryDeps: new bytes[](0),
                    refundRecipient: L2_REFUND_ADDRESS
                })
            );
        } else {
            // An ERC20 that is not WETH.
            IERC20(l1Token).forceApprove(SHARED_BRIDGE, amount);
            txHash = BRIDGE_HUB.requestL2TransactionTwoBridges{ value: txBaseCost }(
                BridgeHubInterface.L2TransactionRequestTwoBridgesOuter({
                    chainId: CHAIN_ID,
                    mintValue: txBaseCost,
                    l2Value: 0,
                    l2GasLimit: L2_GAS_LIMIT,
                    l2GasPerPubdataByteLimit: L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT,
                    refundRecipient: L2_REFUND_ADDRESS,
                    secondBridgeAddress: SHARED_BRIDGE,
                    secondBridgeValue: 0,
                    secondBridgeCalldata: _secondBridgeCalldata(to, l1Token, amount)
                })
            );
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkStackMessageRelayed(txHash);
    }

    /**
     * @notice Computes the calldata for the "second bridge", which handles sending non native tokens.
     * @param l2Recipient recipient of the tokens.
     * @param l1Token the l1 address of the token. Note: ETH is encoded as address(1).
     * @param amount number of tokens to send.
     * @return abi encoded bytes.
     */
    function _secondBridgeCalldata(
        address l2Recipient,
        address l1Token,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encode(l1Token, amount, l2Recipient);
    }

    /**
     * @notice For a given l2 gas limit, this computes the amount of ETH needed and
     * returns the amount.
     * @param l2GasLimit L2 gas limit for the message.
     * @return amount of ETH that this contract needs to provide in order for the l2 transaction to succeed.
     */
    function _computeETHTxCost(uint256 l2GasLimit) internal view returns (uint256) {
        if (tx.gasprice > MAX_TX_GASPRICE) revert TransactionFeeTooHigh();
        return BRIDGE_HUB.l2TransactionBaseCost(CHAIN_ID, tx.gasprice, l2GasLimit, L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT);
    }
}
