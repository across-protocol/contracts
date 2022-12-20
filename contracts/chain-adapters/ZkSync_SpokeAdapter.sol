// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";
import "../SpokePoolInterface.sol";

interface ZkBridgeLike {
    function withdraw(
        address _to,
        address _l2Token,
        uint256 _amount
    ) external;
}

/**
 * @notice Used on ZkSync to send tokens from SpokePool to HubPool
 */
contract ZkSync_SpokeAdapter is SpokeAdapterInterface {
    address public immutable spokePool;

    // Bridge used to withdraw ERC20's to L1: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ERC20Bridge.sol
    ZkBridgeLike public immutable zkErc20Bridge;

    // Bridge used to send ETH to L1: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ETHBridge.sol
    ZkBridgeLike public immutable zkEthBridge;

    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    constructor(
        address _spokePool,
        ZkBridgeLike _zkErc20Bridge,
        ZkBridgeLike _zkEthBridge
    ) {
        spokePool = _spokePool;
        zkErc20Bridge = _zkErc20Bridge;
        zkEthBridge = _zkEthBridge;
    }

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        (l2TokenAddress == address(SpokePoolInterface(spokePool).wrappedNativeToken()) ? zkEthBridge : zkErc20Bridge)
            .withdraw(
                SpokePoolInterface(spokePool).hubPool(),
                // Note: If ETH, must use 0x0: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ETHBridge.sol#L57
                l2TokenAddress == address(SpokePoolInterface(spokePool).wrappedNativeToken())
                    ? address(0)
                    : l2TokenAddress,
                amountToReturn
            );

        emit ZkSyncTokensBridged(l2TokenAddress, SpokePoolInterface(spokePool).hubPool(), amountToReturn);
    }
}
