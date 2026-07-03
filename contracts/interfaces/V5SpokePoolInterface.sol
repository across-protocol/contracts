// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Types and errors for Across V5 SpokePool fills.
 *
 * A V5 deposit carries only a witness across the bridge: `message = V5_MAGIC_PREFIX || stepId`, where `stepId`
 * is the Merkle root of the Gateway execution allowed to consume it. Everything else the destination must honor
 * is committed in the destination path leaf as `V5FillInput`; the submitter supplies the remaining relay data
 * just-in-time as `V5FillJit`. The two together, plus the live stepId read from the Gateway, reconstruct the
 * deposit's `V3RelayData` — so the computed relay hash only matches a real deposit when the committed root is
 * the one being executed.
 *
 * `executeAcrossV5` is the executor-mode entrypoint: the user's path commits the SpokePool itself as the
 * executor, so the Gateway calls it directly and the entire execution is one V5 fill. V5 deposits are
 * alternatively consumable through plain `fillRelay` by a periphery executor committed as the deposit's
 * exclusive relayer. V5 deposits themselves are created outside the SpokePool (see the Across V5
 * SpokePoolExecutor) as ordinary Across deposits whose message is the stamped witness.
 */
interface V5SpokePoolInterface {
    /// @notice Deposit-committed acceptance bounds for a V5 fill, committed in the path leaf under the
    /// deposit's witness root rather than crossing the bridge.
    struct V5FillInput {
        // Account receiving the fill on this chain.
        bytes32 recipient;
        // Token delivered to the recipient. Must be an ERC20.
        bytes32 outputToken;
        // Floor for the submitter-resolved output amount.
        uint256 minOutputAmount;
        // handleV3AcrossMessage payload delivered to a contract recipient after the transfer. Committed under
        // the witness, giving it V3's trust semantics. Empty for plain delivery.
        bytes message;
    }

    /// @notice Submitter-supplied relay data for a V5 fill: competition parameters and facts the submitter
    /// proves by paying for the fill, plus their repayment preferences.
    struct V5FillJit {
        bytes32 depositor;
        bytes32 inputToken;
        uint256 inputAmount;
        // Resolved output amount; must be at least `V5FillInput.minOutputAmount`.
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes32 exclusiveRelayer;
        // Chain and address where the filler wants their refund.
        uint256 repaymentChainId;
        bytes32 repaymentAddress;
    }

    /// @notice Thrown when `executeAcrossV5` is called by anyone other than the Gateway.
    error V5NotGateway();
    /// @notice Thrown when a V5-tagged deposit reaches a settlement path that V5 fills never use (updated
    /// fills, slow-fill requests and executions).
    error V5FillOnly();
    /// @notice Thrown when the submitter-resolved output amount is below the committed floor.
    error V5OutputAmountTooLow();
    /// @notice Thrown when native value is sent to a V5 fill. Fills never accept native value; the V5
    /// entrypoint is payable only because the external V5 executor interface requires it.
    error V5UnusedMsgValue();
}
