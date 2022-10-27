// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ZkSyncLike {
    // Src: https://github.com/matter-labs/v2-testnet-contracts/blob/9fee76e59045df8306576eb09f70ad70b62d0920/l1/contracts/zksync/facets/Mailbox.sol#L95
    /// @notice Request execution of L2 transaction from L1.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Value `msg.value` of L2 transaction. Please note, this ether is not transferred with requesting priority op,
    /// but will be taken from the balance in L2 during the execution
    /// @param _calldata The input of the L2 transaction
    /// @param _ergsLimit Maximum amount of ergs that transaction can consume during execution on L2
    /// @param _factoryDeps An array of L2 bytecodes that will be marked as known on L2
    /// @return canonicalTxHash The hash of the requested L2 transaction. This hash can be used to follow the transaction status
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _ergsLimit,
        bytes[] calldata _factoryDeps
    ) external payable returns (bytes32 canonicalTxHash);
}

interface ZkBridgeLike {
    function deposit(
        address _to,
        address _l1Token,
        uint256 _amount
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
    WETH9 public immutable l1Weth = WETH9(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    // Hardcode the following ZkSync system contract addresses to save gas on construction. This adapter can be
    // redeployed in the event that the following addresses change.

    // Main contract used to send L1 --> L2 messages. Fetchable via `zks_getMainContract` method on JSON RPC.
    ZkSyncLike public immutable zkSync = ZkSyncLike(0xcB3D5008e03Bf569dcdf17259Fa30726ED646931);
    // Bridges to send ERC20 and ETH to L2. Fetchable via `zks_getBridgeContracts` method on JSON RPC.
    ZkBridgeLike public immutable zkErc20Bridge = ZkBridgeLike(0xc0543dab6aC5D3e3fF2E5A5E39e15186d0306808);
    ZkBridgeLike public immutable zkEthBridge = ZkBridgeLike(0xc24215226336d22238a20A72f8E489c005B44C4A);

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
        // _l2Value is a parameter that defines the amount of ETH you want to pass with the call to L2.
        //  This number will be used as msg.value for the transaction.
        // _calldata is a parameter that contains the calldata of the transaction call. It can be encoded the
        //  same way as on Ethereum.
        // _ergsLimit is a parameter that contains the ergs limit of the transaction call. You can learn more about
        //  ergs and the zkSync fee system here: https://v2-docs.zksync.io/dev/developer-guides/transactions/fee-model.html
        // _factoryDeps is a list of bytecodes. It should contain the bytecode of the contract being deployed.
        //  If the contract being deployed is a factory contract, i.e. it can deploy other contracts, the array should also contain the bytecodes of the contracts that can be deployed by it.
        bytes32 txHash = zkSync.requestL2Transaction{ value: txBaseCost }(
            target,
            txBaseCost,
            message,
            ergsLimit,
            new bytes[](0)
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
            // Must set L1Token address to 0x0: https://github.com/matter-labs/v2-testnet-contracts/blob/9fee76e59045df8306576eb09f70ad70b62d0920/l1/contracts/bridge/L1EthBridge.sol#L80
            txHash = zkEthBridge.deposit{ value: txBaseCost + amount }(to, address(0), amount);
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(zkErc20Bridge), amount);
            txHash = zkErc20Bridge.deposit{ value: txBaseCost }(to, l1Token, amount);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkSyncMessageRelayed(txHash);
    }

    /**
     * @notice Returns required amount of ETH to send a message.
     * @dev Apparently you can estimate the L2TransactionBaseCost here: https://v2-docs.zksync.io/dev/developer-guides/bridging/l1-l2.html#using-contract-interface-in-your-project
     *      However, this seems not worth it since the calldata length is fixed
     * *    and we don't need to be too precise.
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
