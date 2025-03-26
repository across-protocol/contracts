// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contains structs and functions used by SpokePool contracts to facilitate universal settlement.
interface V3SpokePoolInterface {
    /**************************************
     *              ENUMS                 *
     **************************************/

    // Fill status tracks on-chain state of deposit, uniquely identified by relayHash.
    enum FillStatus {
        Unfilled,
        RequestedSlowFill,
        Filled
    }
    // Fill type is emitted in the FilledRelay event to assist Dataworker with determining which types of
    // fills to refund (e.g. only fast fills) and whether a fast fill created a sow fill excess.
    enum FillType {
        FastFill,
        // Fast fills are normal fills that do not replace a slow fill request.
        ReplacedSlowFill,
        // Replaced slow fills are fast fills that replace a slow fill request. This type is used by the Dataworker
        // to know when to send excess funds from the SpokePool to the HubPool because they can no longer be used
        // for a slow fill execution.
        SlowFill
    }
    // Slow fills are requested via requestSlowFill and executed by executeSlowRelayLeaf after a bundle containing
    // the slow fill is validated.

    /**************************************
     *              STRUCTS               *
     **************************************/

    // This struct represents the data to fully specify a **unique** relay submitted on this chain.
    // This data is hashed with the chainId() and saved by the SpokePool to prevent collisions and protect against
    // replay attacks on other chains. If any portion of this data differs, the relay is considered to be
    // completely distinct.
    struct V3RelayData {
        // The bytes32 that made the deposit on the origin chain.
        bytes32 depositor;
        // The recipient bytes32 on the destination chain.
        bytes32 recipient;
        // This is the exclusive relayer who can fill the deposit before the exclusivity deadline.
        bytes32 exclusiveRelayer;
        // Token that is deposited on origin chain by depositor.
        bytes32 inputToken;
        // Token that is received on destination chain by recipient.
        bytes32 outputToken;
        // The amount of input token deposited by depositor.
        uint256 inputAmount;
        // The amount of output token to be received by recipient.
        uint256 outputAmount;
        // Origin chain id.
        uint256 originChainId;
        // The id uniquely identifying this deposit on the origin chain.
        uint256 depositId;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp on the destination chain after which any relayer can fill the deposit.
        uint32 exclusivityDeadline;
        // Data that is forwarded to the recipient.
        bytes message;
    }

    // Same as V3RelayData but using addresses instead of bytes32 & depositId is uint32.
    // Will be deprecated in favor of V3RelayData in the future.
    struct V3RelayDataLegacy {
        address depositor;
        address recipient;
        address exclusiveRelayer;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint32 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    // Contains parameters passed in by someone who wants to execute a slow relay leaf.
    struct V3SlowFill {
        V3RelayData relayData;
        uint256 chainId;
        uint256 updatedOutputAmount;
    }

    // Contains information about a relay to be sent along with additional information that is not unique to the
    // relay itself but is required to know how to process the relay. For example, "updatedX" fields can be used
    // by the relayer to modify fields of the relay with the depositor's permission, and "repaymentChainId" is specified
    // by the relayer to determine where to take a relayer refund, but doesn't affect the uniqueness of the relay.
    struct V3RelayExecutionParams {
        V3RelayData relay;
        bytes32 relayHash;
        uint256 updatedOutputAmount;
        bytes32 updatedRecipient;
        bytes updatedMessage;
        uint256 repaymentChainId;
    }

    // Packs together parameters emitted in FilledRelay because there are too many emitted otherwise.
    // Similar to V3RelayExecutionParams, these parameters are not used to uniquely identify the deposit being
    // filled so they don't have to be unpacked by all clients.
    struct V3RelayExecutionEventInfo {
        bytes32 updatedRecipient;
        bytes32 updatedMessageHash;
        uint256 updatedOutputAmount;
        FillType fillType;
    }

    // Represents the parameters required for a V3 deposit operation in the SpokePool.
    struct DepositV3Params {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes32 exclusiveRelayer;
        uint256 depositId;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes message;
    }

    /**************************************
     *              EVENTS                *
     **************************************/

    event FundsDeposited(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint256 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 indexed depositor,
        bytes32 recipient,
        bytes32 exclusiveRelayer,
        bytes message
    );

    event RequestedSpeedUpDeposit(
        uint256 updatedOutputAmount,
        uint256 indexed depositId,
        bytes32 indexed depositor,
        bytes32 updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );

    event FilledRelay(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint256 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 exclusiveRelayer,
        bytes32 indexed relayer,
        bytes32 depositor,
        bytes32 recipient,
        bytes32 messageHash,
        V3RelayExecutionEventInfo relayExecutionInfo
    );

    event RequestedSlowFill(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed originChainId,
        uint256 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 exclusiveRelayer,
        bytes32 depositor,
        bytes32 recipient,
        bytes32 messageHash
    );

    event ClaimedRelayerRefund(
        bytes32 indexed l2TokenAddress,
        bytes32 indexed refundAddress,
        uint256 amount,
        address indexed caller
    );

    /**************************************
     *              FUNCTIONS             *
     **************************************/

    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    function depositNow(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 fillDeadlineOffset,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    function depositV3Now(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 fillDeadlineOffset,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    function unsafeDeposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint256 depositNonce,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) external payable;

    function speedUpDeposit(
        bytes32 depositor,
        uint256 depositId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function speedUpV3Deposit(
        address depositor,
        uint256 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function fillRelay(
        V3RelayData calldata relayData,
        uint256 repaymentChainId,
        bytes32 repaymentAddress
    ) external;

    function fillV3Relay(V3RelayDataLegacy calldata relayData, uint256 repaymentChainId) external;

    function fillRelayWithUpdatedDeposit(
        V3RelayData calldata relayData,
        uint256 repaymentChainId,
        bytes32 repaymentAddress,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function requestSlowFill(V3RelayData calldata relayData) external;

    function executeSlowRelayLeaf(
        V3SlowFill calldata slowFillLeaf,
        uint32 rootBundleId,
        bytes32[] calldata proof
    ) external;

    function claimRelayerRefund(bytes32 l2TokenAddress, bytes32 refundAddress) external;

    /**************************************
     *              ERRORS                *
     **************************************/

    error DisabledRoute();
    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error InvalidExclusiveRelayer();
    error MsgValueDoesNotMatchInputAmount();
    error NotExclusiveRelayer();
    error NoSlowFillsInExclusivityWindow();
    error RelayFilled();
    error InvalidSlowFillRequest();
    error ExpiredFillDeadline();
    error InvalidMerkleProof();
    error InvalidChainId();
    error InvalidMerkleLeaf();
    error ClaimedMerkleLeaf();
    error InvalidPayoutAdjustmentPct();
    error WrongERC7683OrderId();
    error LowLevelCallFailed(bytes data);
    error InsufficientSpokePoolBalanceToExecuteLeaf();
    error NoRelayerRefundToClaim();

    /**************************************
     *             LEGACY EVENTS          *
     **************************************/

    // Note: these events are unused, but included in the ABI for ease of migration.
    event V3FundsDeposited(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint32 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address indexed depositor,
        address recipient,
        address exclusiveRelayer,
        bytes message
    );

    event RequestedSpeedUpV3Deposit(
        uint256 updatedOutputAmount,
        uint32 indexed depositId,
        address indexed depositor,
        address updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );

    // Legacy struct only used to preserve the FilledV3Relay event definition.
    struct LegacyV3RelayExecutionEventInfo {
        address updatedRecipient;
        bytes updatedMessage;
        uint256 updatedOutputAmount;
        FillType fillType;
    }

    event FilledV3Relay(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint32 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer,
        address indexed relayer,
        address depositor,
        address recipient,
        bytes message,
        LegacyV3RelayExecutionEventInfo relayExecutionInfo
    );

    event RequestedV3SlowFill(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed originChainId,
        uint32 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer,
        address depositor,
        address recipient,
        bytes message
    );
}
