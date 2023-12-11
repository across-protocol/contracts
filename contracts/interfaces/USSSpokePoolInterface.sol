// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Contains structs and functions used by SpokePool contracts to facilitate universal settlement.
interface USSSpokePoolInterface {
    enum FillStatus {
        Unfilled,
        RequestedSlowFill,
        Filled
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
        int256 payoutAdjustmentPct;
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
        bool slowFill;
        int256 payoutAdjustmentPct;
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
        bool replacedSlowFillExecution
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

    // TODO: Consider emitting the following events in fillRelayUSSWithUpdatedDeposit
    // and executeUSSSlowRelayLeaf to capture data that USSFilledRelay doesn't. The reason
    // I'm on the fence about this is because the existing dataworker/relayer do not use
    // the sped-up-deposit modified data and I don't anticipate them needing to query
    // the payoutAdjustmentPct. The ones that would would be those tracking relayer balances
    // like relayers themselves and the data teams.

    // event USSFilledModifiedRelay(
    //     uint256 updatedOutputAmount,
    //     address updatedRecipient,
    //     bytes updatedMessage
    // );

    // Emitting these params that are unique to the specific fill transaction, separately because they
    // are unused by the dataworker and relayer when proposing and validating bundles and filling deposits.
    // However, they are useful for tracking relayer balances and data analytics in general.
    event USSRelayExecution(
        int256 payoutAdjustmentPct,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes updatedMessage,
        bool slowFill
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

    function fillUSSRelay(USSRelayData memory relayData, uint256 repaymentChainId) external;

    function requestUSSSlowFill(USSRelayData memory relayData) external;

    function executeUSSSlowRelayLeaf(
        USSSlowFill calldata slowFillLeaf,
        uint32 rootBundleId,
        bytes32[] calldata proof
    ) external;

    function executeUSSRelayerRefundLeaf(
        uint32 rootBundleId,
        USSRelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) external;

    error DisabledRoute();
    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error MsgValueDoesNotMatchInputAmount();
    error NotExclusiveRelayer();
    error RelayFilled();
    error InvalidSlowFill();
    error ExpiredFillDeadline();
    error InvalidMerkleProof();
    error InvalidChainId();
    error InvalidMerkleLeaf();
    error ClaimedMerkleLeaf();
    error InvalidPayoutAdjustmentPct();
}
