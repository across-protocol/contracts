// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Contains structs and functions used by SpokePool contracts to facilitate universal settlement.
interface USSSpokePoolInterface {
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
        // Slow fills are requested via requestSlowFill and executed by executeSlowRelayLeaf after a bundle containing
        // the slow fill is validated.
    }

    // This struct represents the data to fully specify a **unique** relay. This data is hashed and saved by the SpokePool
    // to prevent collisions. If any portion of this data differs, the relay is considered to be completely distinct.
    struct USSRelayData {
        // The address that made the deposit on the origin chain.
        address depositor;
        // The recipient address on the destination chain.
        address recipient;
        // This is the exclusive relayer who can fill the deposit before the exclusivity deadline.
        address exclusiveRelayer;
        // Token that is deposited on origin chain by depositor.
        address inputToken;
        // Token that is received on destination chain by recipient.
        address outputToken;
        // The amount of input token deposited by depositor.
        uint256 inputAmount;
        // The amount of output token to be received by recipient.
        uint256 outputAmount;
        // Origin chain id.
        uint256 originChainId;
        // Destination chain id.
        uint256 destinationChainId;
        // The id uniquely identifying this deposit on the origin chain.
        uint32 depositId;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp on the destination chain after which any relayer can fill the deposit.
        uint32 exclusivityDeadline;
        // Data that is forwarded to the recipient.
        bytes message;
    }

    struct USSSlowFill {
        USSRelayData relayData;
        uint256 updatedOutputAmount;
    }

    struct USSRelayerRefundLeaf {
        // This is the amount to return to the HubPool. This occurs when there is a PoolRebalanceLeaf netSendAmount that
        // is negative. This is just the negative of this value.
        uint256 amountToReturn;
        // Used to verify that this is being executed on the correct destination chainId.
        uint256 chainId;
        // This array designates how much each of those addresses should be refunded.
        uint256[] refundAmounts;
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint32 leafId;
        // The associated L2TokenAddress that these claims apply to.
        address l2TokenAddress;
        // Must be same length as refundAmounts and designates each address that must be refunded.
        address[] refundAddresses;
        // Merkle tree containing each of the fills refunded by this leaf and accounted for in refundAmounts
        // and refundAddresses. The MerkleLeaf structure should be defined in the ACROSS-V2 UMIP, as there is no
        // logic in this contract that supports proving leaf inclusion in this root.
        bytes32 fillsRefundedRoot;
        // Storage layer hash of the file containing all leaves in the fillsRefundedRoot.
        string fillsRefundedHash;
    }

    // Contains information about a relay to be sent along with additional information that is not unique to the
    // relay itself but is required to know how to process the relay. For example, "updatedX" fields can be used
    // by the relayer to modify fields of the relay with the depositor's permission, and "repaymentChainId" is specified
    // by the relayer to determine where to take a relayer refund, but doesn't affect the uniqueness of the relay.
    struct USSRelayExecutionParams {
        USSRelayData relay;
        bytes32 relayHash;
        uint256 updatedOutputAmount;
        address updatedRecipient;
        bytes updatedMessage;
        uint256 repaymentChainId;
    }

    event USSFundsDeposited(
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
        address relayer,
        bytes message
    );

    event RequestedSpeedUpUSSDeposit(
        uint256 updatedOutputAmount,
        uint32 indexed depositId,
        address indexed depositor,
        address updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );

    struct USSRelayExecutionEventInfo {
        address updatedRecipient;
        bytes updatedMessage;
        uint256 updatedOutputAmount;
        FillType fillType;
    }

    event FilledUSSRelay(
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
        USSRelayExecutionEventInfo relayExecutionInfo
    );

    event RequestedUSSSlowFill(
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

    event ExecutedUSSRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        bytes32 fillsRefundedRoot,
        string fillsRefundedIpfsHash
    );

    function depositUSS(
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

    function speedUpUSSDeposit(
        address depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function fillUSSRelay(USSRelayData calldata relayData, uint256 repaymentChainId) external;

    function fillUSSRelayWithUpdatedDeposit(
        USSRelayData calldata relayData,
        uint256 repaymentChainId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function requestUSSSlowFill(USSRelayData calldata relayData) external;

    function executeUSSSlowRelayLeaf(
        USSSlowFill calldata slowFillLeaf,
        uint32 rootBundleId,
        bytes32[] calldata proof
    ) external;

    function executeUSSRelayerRefundLeaf(
        uint32 rootBundleId,
        USSRelayerRefundLeaf calldata relayerRefundLeaf,
        bytes32[] calldata proof
    ) external payable;

    error DisabledRoute();
    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error MsgValueDoesNotMatchInputAmount();
    error NotExclusiveRelayer();
    error RelayFilled();
    error InvalidSlowFillRequest();
    error ExpiredFillDeadline();
    error InvalidMerkleProof();
    error InvalidChainId();
    error InvalidMerkleLeaf();
    error ClaimedMerkleLeaf();
    error InvalidPayoutAdjustmentPct();
}
