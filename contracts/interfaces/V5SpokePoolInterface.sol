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
 * V5 deposits are consumable in two modes:
 * - executor mode (`executeAcrossV5`): the SpokePool is the path executor, called directly by the Gateway.
 * - adapter mode (`adapterExecuteAcrossV5`): the SpokePool is an ADAPTER_CALL target inside a command tape,
 *   called by the live step's committed executor.
 */
interface V5SpokePoolInterface {
    /// @notice Discriminates the action encoded in the tape-committed `input` of `adapterExecuteAcrossV5`:
    /// `input = abi.encodePacked(uint8(action), abi.encode(actionInput))`.
    enum V5AdapterAction {
        Deposit,
        Fill
    }

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
        // the witness, giving it V3's trust semantics. Executor mode only — adapter-mode fills have no trailing
        // call, so it must be empty there.
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
    /// @notice Thrown when `adapterExecuteAcrossV5` is called by anyone other than the live step's committed
    /// executor (also rejects calls while the Gateway is idle or still in its funding loop).
    error V5NotCurrentExecutor();
    /// @notice Thrown when a V5-tagged deposit reaches a non-V5 settlement path (regular fills, updated fills,
    /// slow-fill requests and executions). V5 deposits are consumable only through the witness-checked V5
    /// entrypoints.
    error V5FillOnly();
    /// @notice Thrown when the submitter-resolved output amount is below the committed floor.
    error V5OutputAmountTooLow();
    /// @notice Thrown when native value is sent to a V5 fill, which has no consumer for it.
    error V5UnusedMsgValue();
    /// @notice Thrown when an adapter-mode fill commits a callback message (adapter fills have no trailing call;
    /// delivery-then-action belongs in the tape).
    error V5CallbackNotAllowed();
    /// @notice Thrown for the not-yet-implemented V5 deposit adapter action.
    error V5DepositNotImplemented();
}
