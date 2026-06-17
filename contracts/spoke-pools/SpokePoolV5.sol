// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import { SpokePool } from "./SpokePool.sol";
import { Bytes32ToAddress } from "../libraries/AddressConverters.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @notice Across V5 executor interface (the renamed `IExecutor` from the V5 Gateway/Executor system). A V5
 * `Gateway` invokes `executeAcrossV5Msg(userMsg, submitterMsg)` on its configured `executor` after pulling
 * funding for the step. `userMsg` is the user-committed path message; `submitterMsg` is submitter-provided
 * just-in-time (JIT) data. Recipients that want to run a command tape after receiving funds implement this same
 * interface, so a SpokePool fill can hand off to them.
 */
interface IAcrossV5Executor {
    function executeAcrossV5Msg(bytes calldata userMsg, bytes calldata submitterMsg) external payable;
}

/**
 * @notice Minimal view of the V5 `Gateway` execution context consumed by the SpokePool.
 * @dev `currentStepId()` is assumed to be exposed by the V5 Gateway (planned). `currentPathId()` and
 * `currentSubmitter()` already exist. The Gateway sets these during `execute()` and clears them afterwards.
 */
interface IAcrossV5Gateway {
    function currentSubmitter() external view returns (address submitter);

    function currentPathId() external view returns (bytes32 pathId);

    function currentStepId() external view returns (bytes32 stepId);
}

/**
 * @title SpokePoolV5
 * @notice Compatibility layer that lets a SpokePool act directly as an Across V5 `executor`, collapsing the
 * deposit/fill token flow to the minimum number of transfers.
 *
 * Instead of the V5 `Gateway -> IFunder -> SpokePool -> IFunder -> Executor -> user` hop chain, a relayer calls
 * `Gateway.execute(...)` with the SpokePool itself as the path `executor`. The Gateway then calls
 * `executeAcrossV5Msg` here, which:
 *   - is callable only by the configured `gateway` (`onlyGateway`);
 *   - sources funds from `gateway.currentSubmitter()` via `transferFrom` (the Gateway funding array is empty for
 *     this flow), so a tape-less fill is a single token transfer straight to the recipient;
 *   - reads crucial correctness parameters (deposit/relay params, destination witness) from the user-committed
 *     `userMsg`, while the submitter only contributes JIT data (witness/level, repayment routing) via
 *     `submitterMsg`;
 *   - if the recipient carries a command tape, forwards the funds to it and calls its `executeAcrossV5Msg`,
 *     making the SpokePool an "intermediate executor".
 *
 * V5 messages are tagged with {SpokePool-MAGIC_ACXV5_MESSAGE_PREFIX}: `depositV5` emits `FundsDeposited` with
 * `message = MAGIC || witness`, and `fillV5` emits the standard `FilledRelay` with the identical `message`. The
 * existing relay-hash equality therefore guarantees the submitter is only repaid against a genuine V5 deposit on
 * the origin chain. Because the v4 fill functions reject any MAGIC-prefixed message, a V5-prefixed `FilledRelay`
 * event can only be produced through this Gateway-gated path.
 *
 * @dev OPEN/PROPOSED (pending review): the exact `userMsg` / `submitterMsg` ABI encodings below are a concrete
 * proposal. Also note the V5 `Gateway` must be updated to call `executeAcrossV5Msg` (the planned rename of
 * `IExecutor.execute`) and to expose `currentStepId()`. Chain-specific SpokePool variants must extend this
 * contract (instead of `SpokePool`) and pass `gateway` to the constructor to opt into the V5 path.
 */
abstract contract SpokePoolV5 is SpokePool, IAcrossV5Executor {
    using { SafeERC20Upgradeable.safeTransferFrom } for IERC20Upgradeable;
    using Bytes32ToAddress for bytes32;

    // Address of the V5 Gateway permitted to drive `executeAcrossV5Msg`. Immutable, matching `wrappedNativeToken`.
    address public immutable gateway;

    // userMsg action discriminator. Encoded as the first (uint8) field of the leading static struct so it occupies
    // the first calldata word and can be peeked before decoding the full payload.
    uint8 internal constant ACXV5_ACTION_FILL = 1;
    uint8 internal constant ACXV5_ACTION_DEPOSIT = 2;

    // Commitment level for the fill-side witness, mirroring the Gateway funding module's COMMITMENT_STEP/PATH.
    uint8 internal constant ACXV5_COMMITMENT_STEP = 1;
    uint8 internal constant ACXV5_COMMITMENT_PATH = 2;

    error NotGateway();
    error InvalidV5Action();
    error InvalidCommitmentLevel();
    error WitnessMismatch();

    // User-committed payload for a V5 fill. All fields are static so `typ` lands in the first calldata word.
    // Mirrors V3RelayData minus `message` (which is derived as MAGIC || witness).
    struct AcrossV5FillData {
        uint8 typ; // == ACXV5_ACTION_FILL
        bytes32 depositor;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
    }

    // User-committed payload for a V5 deposit. All fields are static so `typ` lands in the first calldata word.
    struct AcrossV5DepositData {
        uint8 typ; // == ACXV5_ACTION_DEPOSIT
        bytes32 depositor;
        bytes32 recipient;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes32 exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes32 witness; // destination execution scope committed into the deposit message
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _gateway,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer, _oftDstEid, _oftFeeCap) {
        gateway = _gateway;
    }

    /**
     * @notice Across V5 executor entry point. Only the configured Gateway may call this.
     * @param userMsg User-committed path message. Its first word encodes the action discriminator, selecting
     * between a fill ({AcrossV5FillData}) and a deposit ({AcrossV5DepositData}).
     * @param submitterMsg Submitter-provided JIT data (witness/level and, for fills, repayment routing).
     */
    function executeAcrossV5Msg(bytes calldata userMsg, bytes calldata submitterMsg) external payable override {
        if (msg.sender != gateway) revert NotGateway();
        // The economic actor whose funds back this execution: the relayer (fill) or sponsor/depositor (deposit).
        address submitter = IAcrossV5Gateway(gateway).currentSubmitter();

        uint8 action = _peekAction(userMsg);
        if (action == ACXV5_ACTION_FILL) {
            _fillV5(userMsg, submitterMsg, submitter, msg.value);
        } else if (action == ACXV5_ACTION_DEPOSIT) {
            _depositV5(userMsg, submitter);
        } else {
            revert InvalidV5Action();
        }
    }

    /**
     * @notice Lock a V5 deposit on the origin chain, sourcing the input token from the Gateway submitter.
     * @dev The destination `witness` is a user-committed correctness parameter (it binds where/how the funds may be
     * claimed on the destination chain) and is committed into the emitted message as `MAGIC || witness`.
     */
    function _depositV5(bytes calldata userMsg, address submitter) internal {
        if (pausedDeposits) revert DepositsArePaused();

        AcrossV5DepositData memory d = abi.decode(userMsg, (AcrossV5DepositData));

        DepositV3Params memory params = DepositV3Params({
            depositor: d.depositor,
            recipient: d.recipient,
            inputToken: d.inputToken,
            outputToken: d.outputToken,
            inputAmount: d.inputAmount,
            outputAmount: d.outputAmount,
            destinationChainId: d.destinationChainId,
            exclusiveRelayer: d.exclusiveRelayer,
            depositId: numberOfDeposits++,
            quoteTimestamp: d.quoteTimestamp,
            fillDeadline: d.fillDeadline,
            exclusivityParameter: d.exclusivityParameter,
            message: abi.encodePacked(MAGIC_ACXV5_MESSAGE_PREFIX, d.witness)
        });

        // Lock the input token from the submitter (native deposits flow through the forwarded msg.value).
        _depositV3From(submitter, params);
    }

    /**
     * @notice Fill a V5 deposit on the destination chain.
     * @dev Funds move in a single `transferFrom(submitter -> recipient)` for the common (tape-less) case. The relay
     * message is deterministically `MAGIC || witness`, matching the origin deposit so the submitter is repaid only
     * against a genuine V5 deposit. The witness is additionally checked against the live Gateway execution scope, so
     * a fill can only be emitted within the intended Gateway step/path.
     */
    function _fillV5(
        bytes calldata userMsg,
        bytes calldata submitterMsg,
        address submitter,
        uint256 nativeValue
    ) internal {
        if (pausedFills) revert FillsArePaused();

        (AcrossV5FillData memory f, bytes memory recipientMsg) = abi.decode(userMsg, (AcrossV5FillData, bytes));

        // Submitter JIT data: witness + commitment level (validated against the live Gateway scope) and repayment
        // routing (relayer-chosen; does not affect the relay hash). `recipientJit` is forwarded to a tape recipient.
        (
            uint8 level,
            bytes32 witness,
            uint256 repaymentChainId,
            bytes32 repaymentAddress,
            bytes memory recipientJit
        ) = abi.decode(submitterMsg, (uint8, bytes32, uint256, bytes32, bytes));

        _verifyWitness(level, witness);

        V3RelayData memory relayData = V3RelayData({
            depositor: f.depositor,
            recipient: f.recipient,
            exclusiveRelayer: f.exclusiveRelayer,
            inputToken: f.inputToken,
            outputToken: f.outputToken,
            inputAmount: f.inputAmount,
            outputAmount: f.outputAmount,
            originChainId: f.originChainId,
            depositId: f.depositId,
            fillDeadline: f.fillDeadline,
            exclusivityDeadline: f.exclusivityDeadline,
            message: abi.encodePacked(MAGIC_ACXV5_MESSAGE_PREFIX, witness)
        });

        if (relayData.fillDeadline < getCurrentTime()) revert ExpiredFillDeadline();

        // Exclusivity is enforced against the Gateway submitter (the economic relayer), not msg.sender (the Gateway).
        if (
            _fillIsExclusive(relayData.exclusivityDeadline, uint32(getCurrentTime())) &&
            relayData.exclusiveRelayer.toAddress() != submitter
        ) {
            revert NotExclusiveRelayer();
        }

        bytes32 relayHash = getV3RelayHash(relayData);
        FillType fillType = fillStatuses[relayHash] == uint256(FillStatus.RequestedSlowFill)
            ? FillType.ReplacedSlowFill
            : FillType.FastFill;
        if (fillStatuses[relayHash] == uint256(FillStatus.Filled)) revert RelayFilled();
        fillStatuses[relayHash] = uint256(FillStatus.Filled);

        // Emit the standard FilledRelay event so existing dataworker / relayer-refund infrastructure repays the
        // submitter at `repaymentAddress` on `repaymentChainId`.
        _emitFilledRelayEvent(
            V3RelayExecutionParams({
                relay: relayData,
                relayHash: relayHash,
                updatedOutputAmount: relayData.outputAmount,
                updatedRecipient: relayData.recipient,
                updatedMessage: relayData.message,
                repaymentChainId: repaymentChainId
            }),
            relayData,
            repaymentAddress,
            fillType
        );

        _deliverFillFunds(relayData, submitter, recipientMsg, recipientJit, nativeValue);
    }

    /**
     * @notice Move the output token from the submitter to the recipient, then run the recipient's command tape if
     * one was supplied.
     * @dev Tape-less ERC20 fills are a single `transferFrom(submitter -> recipient)`. A tape-less native fill pulls
     * the wrapped token to this contract and unwraps to the recipient. When a tape is present the recipient is
     * itself a V5 executor: it receives the (token) funds and then runs its own tape via `executeAcrossV5Msg`.
     */
    function _deliverFillFunds(
        V3RelayData memory relayData,
        address submitter,
        bytes memory recipientMsg,
        bytes memory recipientJit,
        uint256 nativeValue
    ) internal {
        address outputToken = relayData.outputToken.toAddress();
        address recipient = relayData.recipient.toAddress();
        uint256 amount = relayData.outputAmount;
        bool hasTape = recipientMsg.length > 0;

        if (outputToken == address(wrappedNativeToken) && !hasTape) {
            // Native delivery: pull wrapped token to self, unwrap, and send native to the recipient.
            IERC20Upgradeable(outputToken).safeTransferFrom(submitter, address(this), amount);
            _unwrapwrappedNativeTokenTo(payable(recipient), amount);
        } else {
            // Single transfer straight from the submitter to the recipient.
            IERC20Upgradeable(outputToken).safeTransferFrom(submitter, recipient, amount);
        }

        if (hasTape) {
            IAcrossV5Executor(recipient).executeAcrossV5Msg{ value: nativeValue }(recipientMsg, recipientJit);
        }
    }

    /// @dev Validate the deposit-committed witness against the live Gateway execution scope selected by `level`.
    function _verifyWitness(uint8 level, bytes32 witness) internal view {
        bytes32 expected;
        if (level == ACXV5_COMMITMENT_STEP) expected = IAcrossV5Gateway(gateway).currentStepId();
        else if (level == ACXV5_COMMITMENT_PATH) expected = IAcrossV5Gateway(gateway).currentPathId();
        else revert InvalidCommitmentLevel();
        if (witness == bytes32(0) || witness != expected) revert WitnessMismatch();
    }

    /// @dev Read the action discriminator from the first word of `userMsg` (the leading static `typ` field).
    function _peekAction(bytes calldata userMsg) private pure returns (uint8 action) {
        if (userMsg.length < 32) revert InvalidV5Message();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            action := byte(31, calldataload(userMsg.offset))
        }
    }
}
