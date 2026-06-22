// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import { SpokePool } from "./SpokePool.sol";
import { IGateway } from "../interfaces/IGateway.sol";
import { IExecutor } from "../interfaces/IExecutor.sol";
import { IExecutorAdapter } from "../interfaces/IExecutorAdapter.sol";
import "../libraries/AddressConverters.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @title SpokePoolV5
 * @notice SpokePool variant integrated with the Across V5 Gateway/Executor system.
 *
 * Rather than exposing bespoke `depositV5` / `fillV5` entrypoints, this contract is itself an Across V5 {IExecutor}
 * and {IExecutorAdapter}: both declare the same `execute(bytes,bytes)` selector, so a single {execute} function
 * serves both roles and is reachable two ways inside a `Gateway.execute`:
 *
 *  - As {IExecutor} — the Gateway calls it directly when a path names this SpokePool as its `executor`
 *    (`Gateway -> SpokePool`).
 *  - As {IExecutorAdapter} — the Executor reaches it via an `ADAPTER_CALL` command, so a deposit/fill can be one step
 *    of a larger tape (`Gateway -> Executor -> SpokePool`, alongside swaps, multiple fills, etc.).
 *
 * `execute` decodes `(V5Op op, V5FundsFrom from, bytes payload)`: `op` selects deposit vs. fill and `from` selects the
 * funding source — the live Gateway submitter, or the caller (`msg.sender`, i.e. the Gateway-funded Executor, for
 * gasless flows). Both deposits and fills are ERC-20 only.
 *
 * V5 deposits are tagged with a magic header (`keccak256("AcrossV5Deposit")`) committed in the deposit message and
 * bound to a specific destination Gateway path. The header makes them settleable only through `execute` inside the
 * canonical Gateway: every other fill path — direct `fillRelay`, `fillV3Relay`, `fillRelayWithUpdatedDeposit`, and
 * slow fills — reverts. A V5 fill reconstructs the control message from the live `currentPathId()`, which lets the
 * destination path commit the relay data with an empty message and avoids a circular dependency between the deposit
 * message and the destination pathId. See `SpokePoolV5-design.md` for the full rationale.
 *
 * @dev Mixin layered on top of {SpokePool}. Its `_fillRelayV3` / `_transferTokensToRecipient` / `_pullDepositFunds`
 * overrides are disjoint from the chain pools' `_requireAdminSender` / `_bridgeTokensToHubPool` overrides, so a
 * concrete deployable pool is just `contract X_SpokePoolV5 is X_SpokePool, SpokePoolV5` plus a constructor. The
 * {SpokePool} constructor args are supplied by the chain pool; this mixin's constructor only sets the Gateway.
 * @custom:security-contact bugs@across.to
 */
abstract contract SpokePoolV5 is SpokePool, IExecutor, IExecutorAdapter {
    using { SafeERC20Upgradeable.safeTransferFrom } for IERC20Upgradeable;
    using Bytes32ToAddress for bytes32;
    using AddressToBytes32 for address;

    /// @notice Canonical Across V5 Gateway. V5 deposits/fills read the live execution context from this contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IGateway public immutable gateway;

    /// @notice Magic header marking a deposit as "V5": Gateway-only fillable, settled exclusively through `execute`.
    bytes32 public constant V5_DEPOSIT_HEADER = keccak256("AcrossV5Deposit");

    /// @notice Thrown when a V5 deposit or fill is attempted outside of `execute` / a live Gateway execution.
    error V5RequiresGateway();
    /// @notice Thrown when a slow fill is attempted against a V5 deposit (V5 deposits are Gateway-fill-only).
    error V5SlowFillNotAllowed();

    /// @notice Operation selector decoded from the `execute` message.
    enum V5Op {
        Deposit,
        Fill
    }

    /// @notice Funding-source selector decoded from the `execute` message. `None` (the zero value) is invalid as input
    /// and is also the transient default, which lets the funding hooks detect a V5 message that did not come through
    /// `execute`.
    enum V5FundsFrom {
        None,
        Submitter,
        Caller
    }

    /// @notice ABI-decode target for a `V5Op.Deposit` payload.
    struct DepositV5Args {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes32 exclusiveRelayer;
        uint256 depositNonce;
        bytes32 destinationPathId;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
    }

    /**
     * @notice Sets the canonical Gateway. As a mixin, this constructor intentionally does not invoke the {SpokePool}
     * constructor — the concrete chain pool (e.g. {Ethereum_SpokePool}/{Arbitrum_SpokePool}) supplies those args.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _gateway) {
        gateway = IGateway(_gateway);
    }

    /**
     * @notice Unified Across V5 entrypoint implementing both {IExecutor} (called by the Gateway directly) and
     * {IExecutorAdapter} (reached by the Executor via `ADAPTER_CALL`). Performs one V5 deposit or fill.
     * @dev Carries the inherited persistent `nonReentrant`, which interlocks with the base `deposit`/`fillRelay`
     * entrypoints: a malicious ERC-20 pulled mid-execution cannot reenter a base deposit/fill (forged with a V5
     * header) — it reverts at the shared reentrancy guard. `payable` is required because the Gateway forwards
     * `address(this).balance`; V5 is ERC-20 only, deposits reject any `msg.value`, and a stray balance otherwise just
     * lands in the contract (recoverable) rather than bricking the call.
     * @param message Path-committed `abi.encode(V5Op op, V5FundsFrom from, bytes payload)`. For `Fill`, `payload` is
     * `abi.encode(V3RelayData relayData)` with an empty `relayData.message` (reconstructed from `currentPathId()`);
     * for `Deposit`, `payload` is `abi.encode(DepositV5Args)`.
     * @param executorMessage Submitter-supplied JIT data. For `Fill`, `abi.encode(uint256 repaymentChainId,
     * bytes32 repaymentAddress)`; ignored for `Deposit`.
     */
    function execute(
        bytes calldata message,
        bytes calldata executorMessage
    ) external payable override(IExecutor, IExecutorAdapter) nonReentrant {
        (V5Op op, V5FundsFrom from, bytes memory payload) = abi.decode(message, (V5Op, V5FundsFrom, bytes));
        if (from == V5FundsFrom.None) revert V5RequiresGateway();
        _setV5FundsFrom(from);
        if (op == V5Op.Fill) _executeFill(payload, executorMessage);
        else _executeDeposit(payload);
        _clearV5FundsFrom();
    }

    /**
     * @dev Origin-chain V5 deposit. Tags the deposit V5 (`V5_DEPOSIT_HEADER || destinationPathId`) and derives
     * `depositId = getUnsafeDepositId(source, depositor, depositNonce)`, keyed on the funding source so it is
     * deterministic and committable in the destination `relayData`: the submitter (pinned via `SUBMITTER_REQ`) for a
     * submitter-funded deposit, or `msg.sender` (the fixed Executor) for a gasless caller-funded deposit. The actual
     * pull happens in {_pullDepositFunds}.
     */
    function _executeDeposit(bytes memory payload) private unpausedDeposits {
        DepositV5Args memory a = abi.decode(payload, (DepositV5Args));
        DepositV3Params memory params = DepositV3Params({
            depositor: a.depositor,
            recipient: a.recipient,
            inputToken: a.inputToken,
            outputToken: a.outputToken,
            inputAmount: a.inputAmount,
            outputAmount: a.outputAmount,
            destinationChainId: a.destinationChainId,
            exclusiveRelayer: a.exclusiveRelayer,
            depositId: getUnsafeDepositId(_v5Source(_v5FundsFrom()), a.depositor, a.depositNonce),
            quoteTimestamp: a.quoteTimestamp,
            fillDeadline: a.fillDeadline,
            exclusivityParameter: a.exclusivityParameter,
            message: abi.encodePacked(V5_DEPOSIT_HEADER, a.destinationPathId)
        });
        _depositV3(params);
    }

    /**
     * @dev Destination-chain V5 fill. Only valid inside a Gateway execution: `relayData.message` is overwritten with
     * `V5_DEPOSIT_HEADER || currentPathId()`, so the resulting `relayHash` matches the origin deposit only when this is
     * the exact destination path the deposit committed to (otherwise the fill matches no real deposit and earns no
     * repayment, leaving the deposit refundable). Output is pulled from the funding source and delivered in
     * {_transferTokensToRecipient}.
     */
    function _executeFill(bytes memory payload, bytes calldata executorMessage) private unpausedFills {
        _requireSubmitter(); // a V5 fill binds to currentPathId(); reject fills outside a Gateway execution
        V3RelayData memory relayData = abi.decode(payload, (V3RelayData));
        (uint256 repaymentChainId, bytes32 repaymentAddress) = abi.decode(executorMessage, (uint256, bytes32));
        relayData.message = abi.encodePacked(V5_DEPOSIT_HEADER, gateway.currentPathId());

        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: getV3RelayHash(relayData),
            updatedOutputAmount: relayData.outputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: repaymentChainId
        });

        _fillRelayV3(relayExecution, repaymentAddress, false);
    }

    /**
     * @dev Funds a V5 deposit (ERC-20 only) from the source `execute` selected. Non-V5 deposits fall through to the
     * base `msg.sender` pull. A V5-tagged message that did not come through `execute` has no funding source set and
     * reverts.
     */
    function _pullDepositFunds(DepositV3Params memory params) internal virtual override {
        if (!_isV5Deposit(params.message)) {
            super._pullDepositFunds(params);
            return;
        }
        V5FundsFrom from = _v5FundsFrom();
        if (from == V5FundsFrom.None) revert V5RequiresGateway();
        if (msg.value != 0) revert MsgValueDoesNotMatchInputAmount();
        IERC20Upgradeable(params.inputToken.toAddress()).safeTransferFrom(
            _v5Source(from),
            address(this),
            params.inputAmount
        );
    }

    /**
     * @dev Gate: a V5 deposit can only be settled through `execute` inside a Gateway execution, and never via slow
     * fill. This blocks direct `fillRelay` / `fillV3Relay` / `fillRelayWithUpdatedDeposit` / `executeSlowRelayLeaf` for
     * V5 deposits (a forged V5-tagged message has no funding source set and reverts).
     */
    function _fillRelayV3(
        V3RelayExecutionParams memory relayExecution,
        bytes32 relayer,
        bool isSlowFill
    ) internal virtual override {
        if (_isV5Deposit(relayExecution.relay.message)) {
            if (isSlowFill) revert V5SlowFillNotAllowed();
            if (_v5FundsFrom() == V5FundsFrom.None) revert V5RequiresGateway();
        }
        super._fillRelayV3(relayExecution, relayer, isSlowFill);
    }

    /**
     * @dev For V5 fills, pull the output token (ERC-20 only) from the funding source and deliver it to the recipient.
     * The V5 message is protocol control data, so the `handleV3AcrossMessage` callback is skipped and the recipient
     * may be an EOA. Non-V5 fills fall back to the base behavior. V5 slow fills are unreachable (blocked in
     * `_fillRelayV3`), so `isSlowFill` is always false here for V5 deposits.
     */
    function _transferTokensToRecipient(
        V3RelayExecutionParams memory relayExecution,
        V3RelayData memory relayData,
        bool isSlowFill
    ) internal virtual override {
        if (!_isV5Deposit(relayData.message)) {
            super._transferTokensToRecipient(relayExecution, relayData, isSlowFill);
            return;
        }
        IERC20Upgradeable(relayData.outputToken.toAddress()).safeTransferFrom(
            _v5Source(_v5FundsFrom()),
            relayExecution.updatedRecipient.toAddress(),
            relayExecution.updatedOutputAmount
        );
    }

    /// @dev Resolves the funding-source address: the live Gateway submitter (reverting if there is none) for a
    ///      submitter-funded op, or `msg.sender` (the Executor / direct caller) for a caller-funded op.
    function _v5Source(V5FundsFrom from) private view returns (address) {
        return from == V5FundsFrom.Submitter ? _requireSubmitter() : msg.sender;
    }

    /// @dev Returns the live Gateway submitter, reverting if there is none (i.e. not inside a Gateway execution).
    function _requireSubmitter() internal view returns (address submitter) {
        submitter = gateway.currentSubmitter();
        if (submitter == address(0)) revert V5RequiresGateway();
    }

    /// @dev True if `message` begins with the V5 header word.
    function _isV5Deposit(bytes memory message) internal pure returns (bool) {
        if (message.length < 32) return false;
        bytes32 header;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            header := mload(add(message, 32))
        }
        return header == V5_DEPOSIT_HEADER;
    }

    // ─── V5 funding-source flag (EIP-1153 transient storage) ──────────────────────────────────
    // The funding pull happens inside the shared `_depositV3` / `_fillRelayV3`, below the point where `execute` knows
    // the chosen source. `execute` stashes `V5FundsFrom` here so the funding hooks can resolve the source, then clears
    // it. Because `execute` is `nonReentrant` (interlocking with base deposit/fill), no other deposit/fill can observe
    // a stale value mid-call; clearing on return keeps the default (`None`) outside an `execute`, which is what lets
    // the hooks reject a forged V5-tagged message that bypassed `execute`.
    bytes32 private constant V5_FUNDS_FROM_TSLOT = keccak256("across.spokePoolV5.transient.fundsFrom");

    function _setV5FundsFrom(V5FundsFrom from) private {
        bytes32 slot = V5_FUNDS_FROM_TSLOT;
        uint256 value = uint256(from);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            tstore(slot, value)
        }
    }

    function _v5FundsFrom() private view returns (V5FundsFrom from) {
        bytes32 slot = V5_FUNDS_FROM_TSLOT;
        uint256 value;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            value := tload(slot)
        }
        from = V5FundsFrom(value);
    }

    function _clearV5FundsFrom() private {
        bytes32 slot = V5_FUNDS_FROM_TSLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            tstore(slot, 0)
        }
    }
}
