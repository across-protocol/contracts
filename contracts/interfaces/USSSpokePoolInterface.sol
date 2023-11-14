// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Contains structs and functions used by SpokePool contracts to facilitate universal settlement.
interface USSSpokePoolInterface {
    enum RelayExecutionType {
        FastFill, // Fast relay execution is the default and is used for most relays by calling
        // `fillRelay()` or `fillRelayWithUpdatedDeposit`.
        SlowFill, // Slow relay execution can be done after the dataworker includes a slow relay leaf in the root bundle
        // proposal, which propogates the leaf to this SpokePool and someone calls executeSlowRelayLeaf().
        DepositRefund // Deposit refunds are included similarly to Slow relay leaves but are distinguished for the
        // convenience of off-chain actors who may want to treat slow fill execution differently from deposit
        // refund execution. For example, deposit refunds are expected to have `message` fields with helpful
        // information to define the deposit for the refund callback address, but typically, an off-chain actor
        // would not want to execute slow fill leaves with messages because they might be rebating the slow fill
        // recipient their relayer fees unintentionally.
    }
    // This struct represents the data to fully specify a **unique** relay. This data is hashed and saved by the SpokePool
    // to prevent collisions. If any portion of this data differs, the relay is considered to be completely distinct.
    struct USSRelayData {
        // The address that made the deposit on the origin chain.
        address depositor;
        // The recipient address on the destination chain.
        address recipient;
        // If this address is not 0x0, then only this address can fill the deposit. Consider this therefore a
        // "committed relayer" address.
        address relayer;
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
        // Data that is forwarded to the recipient.
        bytes message;
    }

    struct USSSlowFill {
        USSRelayData relayData;
        RelayExecutionType executionType;
        int256 payoutAdjustmentPct;
    }

    // Contains information about a relay to be sent along with additional information that is not unique to the
    // relay itself but is required to know how to process the relay. For example, "updatedX" fields can be used
    // by the relayer to modify fields of the relay with the depositor's permission, and "repaymentChainId" is specified
    // by the relayer to determine where to take a relayer refund, but doesn't affect the uniqueness of the relay.
    struct USSRelayExecution {
        USSRelayData relay;
        bytes32 relayHash;
        uint256 updatedOutputAmount;
        address updatedRecipient;
        bytes updatedMessage;
        uint256 repaymentChainId;
        RelayExecutionType executionType;
        int256 payoutAdjustmentPct;
    }

    // @dev The following deposit parameters are packed into structs to avoid stack too deep errors when
    // emitting events like FundsDeposited/FilledRelay that emit
    // a lot of individual parameters.

    /// @dev tokens that need to be sent from the offerer in order to satisfy an order.
    struct InputToken {
        address token;
        uint256 amount;
    }

    /// @dev tokens that need to be received by the recipient on another chain in order to satisfy an order
    struct OutputToken {
        address token;
        uint256 amount;
    }

    event USSFundsDeposited(
        InputToken inputToken,
        OutputToken outputToken,
        uint256 indexed destinationChainId,
        uint32 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        address indexed depositor,
        address recipient,
        address relayer,
        address depositRefundCallbackAddress,
        bytes message
    );

    event USSFilledRelay(
        InputToken inputToken,
        OutputToken outputToken,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint32 indexed depositId,
        uint32 fillDeadline,
        address indexed relayer,
        address depositor,
        address recipient,
        bytes message,
        // Parameters with "updated" prefix to signal that these parameters can be updated via speed ups.
        address updatedRecipient,
        RelayExecutionType executionType,
        uint256 updatedOutputAmount,
        int256 payoutAdjustmentPct,
        bytes updatedMessage
    );

    function depositUSS(
        address depositor,
        address recipient,
        address depositRefundCallbackAddress,
        // TODO: Running into stack-too-deep errors when emitting FundsDeposited with all of the parameters
        // so I've packed them for now into input and output token structs
        InputToken memory inputToken,
        OutputToken memory outputToken,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        bytes memory message
    ) external payable;

    function fillRelayUSS(
        address depositor,
        address recipient,
        address exclusiveRelayer,
        InputToken memory inputToken,
        OutputToken memory outputToken,
        uint256 repaymentChainId,
        uint256 originChainId,
        uint32 depositId,
        uint32 fillDeadline,
        bytes memory message
    ) external;
}