// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

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

// solhint-disable-next-line contract-name-camelcase
contract ZkSync_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    uint256 public immutable l2GasPrice = 1e9;

    uint32 public immutable ergsLimit = 1_000_000;

    WETH9 public immutable l1Weth = WETH9(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    ZkSyncLike public immutable zkSync = ZkSyncLike(0xa0F968EbA6Bbd08F28Dc061C7856C15725983395);
    ZkBridgeLike public immutable zkErc20Bridge = ZkBridgeLike(0x7786255495348c08F82C09C82352019fAdE3BF29);
    ZkBridgeLike public immutable zkEthBridge = ZkBridgeLike(0xcbebcD41CeaBBC85Da9bb67527F58d69aD4DfFf5);

    event ZkSyncMessageRelayed(bytes32 txHash);

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

        // TODO: Figure out how to estimate the txBaseCost
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

    function relayTokens(
        address l1Token,
        address l2Token, // l2Token is unused.
        uint256 amount,
        address to
    ) external payable override {
        uint256 txBaseCost = _contractHasSufficientEthBalance();

        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge along with the base
        // cost.
        bytes32 txHash;
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            txHash = zkEthBridge.deposit{ value: txBaseCost + amount }(to, l1Token, amount, QueueType.Deque);
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(zkErc20Bridge), amount);
            txHash = zkErc20Bridge.deposit{ value: txBaseCost }(to, l1Token, amount, QueueType.Deque);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
        emit ZkSyncMessageRelayed(txHash);
    }

    function getL1CallValue() public pure returns (uint256) {
        return l2GasPrice * ergsLimit;
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
