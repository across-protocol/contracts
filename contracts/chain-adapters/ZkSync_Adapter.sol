// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Importing `Operations` contract which has the `QueueType` type
import "@matterlabs/zksync-contracts/l1/contracts/zksync/Operations.sol";

interface ZkSyncLike {
    function requestL2Transaction(
        address _contractAddressL2,
        bytes calldata _calldata,
        uint256 _ergsLimit,
        bytes[] calldata _factoryDeps,
        QueueType _queueType
    ) external payable returns (bytes32 txHash);
}

interface ZkBridgeLike {
    function deposit(
        address _to,
        address _l1Token,
        uint256 _amount,
        QueueType _queueType
    ) external payable returns (bytes32 txHash);
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

    // We need to pay a fee to submit transactions to the L1 --> L2 priority queue:
    // https://v2-docs.zksync.io/dev/zksync-v2/l1-l2-interop.html#priority-queue

    // The fee for a transactionis equal to `txBaseCost * gasPrice` where `txBaseCost` depends on the ergsLimit
    // (ergs = gas on ZkSync) and the calldata length. More details here:
    // https://v2-docs.zksync.io/dev/guide/l1-l2.html#using-contract-interface-in-your-project

    // Generally, the ergsLimit and l2GasPrice params are a bit hard to set and may change in the future once ZkSync
    // is deployed to mainnet. On testnet, gas price is set to 0 and gas used is 0 so its hard to accurately forecast.
    uint256 public immutable l2GasPrice = 1e9;

    uint32 public immutable ergsLimit = 1_000_000;

    // Hardcode WETH address for L1 since it will not change:
    WETH9Interface public immutable l1Weth = WETH9Interface(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    // Hardcode the following ZkSync system contract addresses to save gas on construction. This adapter can be
    // redeployed in the event that the following addresses change.

    // Main contract used to send L1 --> L2 messages. Fetchable via `zks_getMainContract` method on JSON RPC.
    ZkSyncLike public immutable zkSync = ZkSyncLike(0xa0F968EbA6Bbd08F28Dc061C7856C15725983395);
    // Bridges to send ERC20 and ETH to L2. Fetchable via `zks_getBridgeContracts` method on JSON RPC.
    ZkBridgeLike public immutable zkErc20Bridge = ZkBridgeLike(0x7786255495348c08F82C09C82352019fAdE3BF29);
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

        // Parameters passed to requestL2Transaction:
        // _contractAddressL2 is a parameter that defines the address of the contract to be called.
        // _calldata is a parameter that contains the calldata of the transaction call. It can be encoded the
        //  same way as on Ethereum.
        // _ergsLimit is a parameter that contains the ergs limit of the transaction call. You can learn more about
        //  ergs and the zkSync fee system here: https://v2-docs.zksync.io/dev/zksync-v2/fee-model.html
        // _factoryDeps is a list of bytecodes. It should contain the bytecode of the contract being deployed.
        //  If the contract being deployed is a factory contract, i.e. it can deploy other contracts, the array should also contain the bytecodes of the contracts that can be deployed by it.
        // _queueType is a parameter required for the priority mode functionality. For the testnet,
        //  QueueType.Deque should always be supplied.
        bytes32 txHash = zkSync.requestL2Transaction{ value: txBaseCost }(
            target,
            message,
            ergsLimit,
            new bytes[](0),
            QueueType.Deque
        );

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
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        // If the l1Token is WETH then unwrap it to ETH then send the ETH to the standard bridge along with the base
        // cost.
        bytes32 txHash;
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            // Must set L1Token address to 0x0: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l1/contracts/bridge/L1EthBridge.sol#L78
            txHash = zkEthBridge.deposit{ value: txBaseCost + amount }(to, address(0), amount, QueueType.Deque);
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(zkErc20Bridge), amount);
            txHash = zkErc20Bridge.deposit{ value: txBaseCost }(to, l1Token, amount, QueueType.Deque);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkSyncMessageRelayed(txHash);
    }

    /**
     * @notice Returns required amount of ETH to send a message.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue() public pure returns (uint256) {
        return l2GasPrice * ergsLimit;
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
