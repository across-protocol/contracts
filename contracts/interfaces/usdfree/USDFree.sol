// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IPermit2 } from "../../external/interfaces/IPermit2.sol";

struct Call {
    address target;
    bytes callData;
}

struct TokenReq {
    address token;
    uint256 minAmount;
}

struct SubmitterRequirement {
    bool delegated;
    // submitterData - if delegated then decodes to (submitterAddress, backendSignature)
    //  if not delegated then decodes to submitterAddress
    bytes submitterData;
}

struct BridgeParams {
    uint256 srcChainId;
    uint256 dstChainId;
    address bridgeAdapter;
    bytes bridgeData; // includes bridge specific data like fees, finality threshold, etc.
}

struct Order {
    address tokenIn;
    uint256 amountIn;
    uint256 deadline;
    SubmitterRequirement submitterRequirement;
    TokenReq srcTokenReq;
    TokenReq dstTokenReq;
    // dstActions: 1st byte indicates if obfuscated
    // if not obfuscated then decodes as (TokenReq dstTokenRequirement, Call[] dstActions)
    // if obfuscated then is a hash of (TokenReq dstTokenRequirement, Call[] dstActions)
    bytes dstPayload;
    BridgeParams bridgeParams;
    bytes32 salt;
}

interface IGateway {
    /**
     * 1) Check deadline (should this be here or in the exeuctor?)
     * 2) Pulls (transferFrom)tokens from user
     * 3) Hashes Order to get orderID and emits it in event
     * 4) Approves Executor to spend tokens
     * 5) Calls executeOrder on Executor
     */
    function submitOrderFromUser(Order calldata order, Call[] calldata srcActions) external;

    /**
     * 1) Check submitter
     * 2) Check deadline (should this be here or in the exeuctor?)
     * 3) Pulls (transferFrom) tokens from user
     * 4) Approves Executor to spend tokens
     * 5) Calls executeOrder on Executor
     * 6) Hashes Order to get orderID and emits it in event
     */
    function submitOrderPermit2(
        Order calldata order,
        Call[] calldata srcActions,
        address depositor, // signer of the permit2 signature
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;
}

interface ISrcExecutor {
    /**
     * 1) Pulls tokens from Gateway
     * 2) Executes srcActions
     * 3) Checks order.srcTokenReq
     * 4) Approves BridgeAdapter to spend tokens
     * 5) Encodes the following into bridgeData and calls deposit() on the bridge adapter
     *    - order.bridgeParams.bridgeData
     *    - order.deadline
     *    - order.submitterRequirement
     *    - order.dstPayload
     */
    function executeOrder(Order calldata order, Call[] calldata srcActions) external;
}

interface IBridgeAdapter {
    /**
     * Decodes bridgeData into bridge specific data
     * Multiple implementations of this for each bridge type, finally calling:
     * - cctpTokenMessenger.depositForBurnWithHook()
     * - oftMessenger.send()
     * - spokePool.deposit()
     */
    function deposit(address token, uint256 amount, uint256 dstChainId, bytes calldata bridgeData) external;
}

interface IIntentStore {
    /**
     * Called by OFT or CCTP receiver
     * 1) Pulls tokens for OFT/CCTP receiver
     * 2) If dstPayload is unobfuscated, try/catch call to dstExecutor.executeOrder()
     * 3) If try/catch fails, store intent data in mapping against a localKey
     */
    function receiveIntent(
        address token,
        uint256 amount,
        uint256 deadline,
        bytes calldata dstPayload,
        SubmitterRequirement calldata submitterRequirement
    ) external;

    /**
     * For a non-obfuscated dstPayload
     * 1) Checks submitterRequirement
     * 2) Checks deadline
     * 3) Approve DstExecutor to spend tokens
     * 4) Calls dstExecutor.executeOrder()
     */
    function fillIntent(uint256 localKey, Call[] calldata submitterActions) external;

    /**
     * For an obfuscated dstPayload
     * 1) Checks submitterRequirement
     * 2) Checks deadline
     * 3) Check that keccak256(dstTokenReq, dstUserActions) == dstPayload
     * 4) Approve DstExecutor to spend tokens
     * 5) Calls dstExecutor.executeOrder()
     */
    function fillObfuscatedIntent(
        uint256 localKey,
        Call[] calldata submitterActions,
        TokenReq calldata dstTokenReq,
        Call[] calldata dstUserActions
    ) external;
}

interface IDstExecutor {
    /**
     * 1) Pull tokens from IntentStore
     * 2) Execute submitterActions
     * 3) Check dstTokenReq
     * 4) Execute dstUserActions
     */
    function executeOrder(
        address token,
        uint256 amount,
        Call[] calldata submitterActions,
        TokenReq calldata dstTokenReq,
        Call[] calldata dstUserActions
    ) external;
}
