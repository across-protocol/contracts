// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IPolygonZkEVMBridge } from "../external/interfaces/IPolygonZkEVMBridge.sol";

/**
 * @notice Mock implementation of Polygon zkEVM's Bridge.
 * @dev Used for testing PolygonZkEVM_SpokePool functionality.
 */
contract MockPolygonZkEVMBridge is IPolygonZkEVMBridge {
    uint256 public bridgeAssetCallCount;

    event BridgeAssetCalled(
        uint32 indexed destinationNetwork,
        address indexed destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes permitData
    );

    struct BridgeAssetCall {
        uint32 destinationNetwork;
        address destinationAddress;
        uint256 amount;
        address token;
        bool forceUpdateGlobalExitRoot;
        bytes permitData;
        uint256 value;
    }
    BridgeAssetCall public lastBridgeAssetCall;

    function bridgeAsset(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external payable override {
        bridgeAssetCallCount++;
        lastBridgeAssetCall = BridgeAssetCall({
            destinationNetwork: destinationNetwork,
            destinationAddress: destinationAddress,
            amount: amount,
            token: token,
            forceUpdateGlobalExitRoot: forceUpdateGlobalExitRoot,
            permitData: permitData,
            value: msg.value
        });
        emit BridgeAssetCalled(
            destinationNetwork,
            destinationAddress,
            amount,
            token,
            forceUpdateGlobalExitRoot,
            permitData
        );
    }

    function bridgeMessage(
        uint32 destinationNetwork,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot,
        bytes calldata metadata
    ) external payable override {
        // Not needed for SpokePool tests
    }

    // Allow receiving ETH
    receive() external payable {}
}
