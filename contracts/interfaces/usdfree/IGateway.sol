// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

struct Call {
    address target;
    bytes callData;
}

struct TokenReq {
    address token;
    uint256 minAmount;
}

enum BridgeType {
    CCTP,
    OFT,
    SPOKE
}

struct BridgeParams {
    uint256 srcChainId;
    uint256 dstChainId;
    BridgeType bridgeType;
    bytes bridgeData;
}

// bool dstObfuscated;
struct Order {
    uint256 deadline;
    // Call[] srcActions;
    TokenReq srcTokenReq;
    TokenReq dstTokenReq;
    BridgeParams bridgeParams;
    bytes32 salt;
}

interface IGateway {
    /**
     * 1) Check deadline (should this be here or in the exeuctor?)
     * 2) Pulls (transferFrom)tokens from user
     * 3) Approves Executor to spend tokens
     * 4) Calls executeOrder on Executor
     * 5) Hashes Order to get orderID and emits it in event
     */
    function submitOrderFromUser(Order calldata order) external;

    /**
     * 1) Check submitter
     * 2) Check deadline (should this be here or in the exeuctor?)
     * 3) Pulls (transferFrom)tokens from user
     * 4) Approves Executor to spend tokens
     * 5) Calls executeOrder on Executor
     * 6) Hashes Order to get orderID and emits it in event
     */
    function submitOrderFromSubmitter(
        Order calldata order,
        Call[] calldata srcActions,
        bytes calldata submitterData
    ) external;
}

interface IExecutor {
    // obfuscated dstActions?
    function executeOrderFromUser(
        Order calldata order,
        Call[] calldata srcActions,
        Call[] calldata dstActions
    ) external;

    function executeOrderFromSubmitter(Order calldata order, Call[] calldata srcActions) external;
}

interface IBridge {}
