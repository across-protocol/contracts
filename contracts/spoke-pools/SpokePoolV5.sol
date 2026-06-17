// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import { SpokePool } from "./SpokePool.sol";
import { Bytes32ToAddress } from "../libraries/AddressConverters.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";

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
 * @dev `currentStepId()` is assumed to be exposed by the V5 Gateway (planned); `currentSubmitter()` already
 * exists. The Gateway sets these during `execute()` and clears them afterwards.
 */
interface IAcrossV5Gateway {
    function currentSubmitter() external view returns (address submitter);

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
 *     `userMsg`, while the submitter only contributes JIT data via `submitterMsg`;
 *   - if the recipient carries a command tape, forwards the funds to it and calls its `executeAcrossV5Msg`,
 *     making the SpokePool an "intermediate executor".
 *
 * V5 messages are tagged with {SpokePool-MAGIC_ACXV5_MESSAGE_PREFIX}: `depositV5Unsafe` emits `FundsDeposited`
 * with `message = MAGIC || witness`, and `fillV5` emits the standard `FilledRelay` with the identical `message`.
 * The existing relay-hash equality therefore guarantees the submitter is only repaid against a genuine V5 deposit
 * on the origin chain. Because the v4 fill functions reject any MAGIC-prefixed message, a V5-prefixed
 * `FilledRelay` event can only be produced through this Gateway-gated path. The committed witness is the
 * destination step's id (`stepId`), which is shared across chains by construction; `fillV5` validates it against
 * the live destination-chain Gateway step.
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

    // Domain separator binding auction-authority signatures to the auction type and this Gateway instance.
    bytes32 public immutable auctionResolutionDomain;

    // userMsg action discriminator, carried as the first raw byte of userMsg (the payload follows from byte 1).
    uint8 internal constant ACXV5_ACTION_FILL = 1;
    uint8 internal constant ACXV5_ACTION_DEPOSIT = 2;

    bytes32 internal constant ACXV5_AUCTION_NAMEHASH = keccak256("ACXV5.SpokePool.AuctionResolution.V1");

    error NotGateway();
    error InvalidV5Action();
    error WitnessMismatch();
    error OutputBelowMinimum(uint256 minimumOutputAmount, uint256 resolvedOutputAmount);
    error InvalidAuctionSignature(address authority);

    // User-committed payload for a V5 fill. Mirrors V3RelayData minus `message` (derived as MAGIC || witness).
    // `outputAmount` is the floor that is emitted and repaid; the submitter may deliver more (see `_fillV5`).
    struct AcrossV5FillData {
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

    // User-committed payload for a V5 deposit. `outputAmount` is the floor; the resolved amount
    // (auction- or submitter-supplied) must be >= it.
    struct AcrossV5DepositData {
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
        bytes32 witness; // destination step id committed into the deposit message
        address auctionAuthority; // if non-zero: auction mode, this signer must authorize the resolved amount
        uint256 fillId; // disambiguates multiple deposits/auctions for the same origin step
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
        auctionResolutionDomain = keccak256(abi.encode(ACXV5_AUCTION_NAMEHASH, _gateway));
    }

    /**
     * @notice Across V5 executor entry point. Only the configured Gateway may call this.
     * @param userMsg User-committed path message: the first byte is the action discriminator, the remaining bytes
     * are the abi-encoded payload ({AcrossV5FillData} for a fill, {AcrossV5DepositData} for a deposit).
     * @param submitterMsg Submitter-provided JIT data.
     */
    function executeAcrossV5Msg(bytes calldata userMsg, bytes calldata submitterMsg) external payable override {
        if (msg.sender != gateway) revert NotGateway();
        // The economic actor whose funds back this execution: the relayer (fill) or sponsor/depositor (deposit).
        address submitter = IAcrossV5Gateway(gateway).currentSubmitter();

        // The first raw byte selects the action; everything after it is the abi-encoded payload.
        uint8 action = uint8(userMsg[0]);
        bytes calldata payload = userMsg[1:];
        if (action == ACXV5_ACTION_FILL) {
            _fillV5(payload, submitterMsg, submitter, msg.value);
        } else if (action == ACXV5_ACTION_DEPOSIT) {
            _depositV5Unsafe(payload, submitterMsg, submitter);
        } else {
            revert InvalidV5Action();
        }
    }

    /**
     * @notice Lock a V5 deposit on the origin chain, sourcing the input token from the Gateway submitter.
     * @dev V5 does not support incremental-nonce deposits; the deposit id is always derived from the origin
     * `stepId` (like `unsafeDeposit`), with `nonce = keccak(stepId, fillId)`. The submitter always supplies the
     * resolved output amount (>= the user floor) so it can bump the amount up. When `auctionAuthority` is non-zero
     * (auction mode), that resolved amount must additionally be authorized by the authority's signature. The
     * destination `witness` is a user-committed correctness parameter committed into the message as
     * `MAGIC || witness`.
     */
    function _depositV5Unsafe(bytes calldata userMsg, bytes calldata submitterMsg, address submitter) internal {
        if (pausedDeposits) revert DepositsArePaused();

        AcrossV5DepositData memory d = abi.decode(userMsg, (AcrossV5DepositData));
        bytes32 originStepId = IAcrossV5Gateway(gateway).currentStepId();

        // The submitter always resolves the output amount; in auction mode it also carries the authority signature.
        (uint256 resolvedOutputAmount, bytes memory signature) = abi.decode(submitterMsg, (uint256, bytes));
        if (resolvedOutputAmount < d.outputAmount) revert OutputBelowMinimum(d.outputAmount, resolvedOutputAmount);

        // Auction mode: the resolved amount must be authorized by the committed authority for (stepId, fillId).
        if (d.auctionAuthority != address(0)) {
            bytes32 digest = auctionDigest(originStepId, d.fillId, resolvedOutputAmount);
            if (!SignatureChecker.isValidSignatureNow(d.auctionAuthority, digest, signature)) {
                revert InvalidAuctionSignature(d.auctionAuthority);
            }
        }

        uint256 depositNonce = uint256(keccak256(abi.encodePacked(originStepId, d.fillId)));

        DepositV3Params memory params = DepositV3Params({
            depositor: d.depositor,
            recipient: d.recipient,
            inputToken: d.inputToken,
            outputToken: d.outputToken,
            inputAmount: d.inputAmount,
            outputAmount: resolvedOutputAmount,
            destinationChainId: d.destinationChainId,
            exclusiveRelayer: d.exclusiveRelayer,
            depositId: getUnsafeDepositId(submitter, d.depositor, depositNonce),
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
     * against a genuine V5 deposit. The witness is additionally validated against the live destination Gateway
     * step, so a fill can only be emitted within the intended Gateway step.
     *
     * The submitter may deliver more than the committed `outputAmount` (the relayer sponsors the recipient's
     * execution tape): the larger resolved amount is sent to the recipient, but the emitted/repaid relay still
     * uses the committed `outputAmount`.
     */
    function _fillV5(
        bytes calldata userMsg,
        bytes calldata submitterMsg,
        address submitter,
        uint256 nativeValue
    ) internal {
        if (pausedFills) revert FillsArePaused();

        (AcrossV5FillData memory f, bytes memory recipientMsg) = abi.decode(userMsg, (AcrossV5FillData, bytes));

        // Submitter JIT data: witness (validated against the live destination Gateway step), repayment routing
        // (relayer-chosen; not part of the relay hash), an optional over-delivery amount, and tape JIT data.
        (
            bytes32 witness,
            uint256 repaymentChainId,
            bytes32 repaymentAddress,
            uint256 resolvedOutputAmount,
            bytes memory recipientJit
        ) = abi.decode(submitterMsg, (bytes32, uint256, bytes32, uint256, bytes));

        if (witness == bytes32(0) || witness != IAcrossV5Gateway(gateway).currentStepId()) revert WitnessMismatch();

        // The submitter may sponsor the recipient's tape by delivering more than the committed floor.
        if (resolvedOutputAmount < f.outputAmount) revert OutputBelowMinimum(f.outputAmount, resolvedOutputAmount);

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

        // `updatedOutputAmount` reflects what is actually delivered; the relay's `outputAmount` (in the hash and
        // repaid to the relayer) stays at the committed floor.
        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: getV3RelayHash(relayData),
            updatedOutputAmount: resolvedOutputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: repaymentChainId
        });

        // Shared pipeline: deadline + exclusivity (against the submitter, the economic relayer) + status dedup +
        // standard FilledRelay event (so existing dataworker / refund infra repays the submitter).
        _commitFill(relayExecution, repaymentAddress, submitter, false);

        _transferTokensToRecipientV5(
            relayData,
            submitter,
            resolvedOutputAmount,
            recipientMsg,
            recipientJit,
            nativeValue
        );
    }

    /**
     * @notice Move the output token from the submitter to the recipient, then run the recipient's command tape if
     * one was supplied.
     * @dev Tape-less ERC20 fills are a single `transferFrom(submitter -> recipient)`. A tape-less native fill pulls
     * the wrapped token to this contract and unwraps to the recipient. When a tape is present the recipient is
     * itself a V5 executor: it receives the (token) funds and then runs its own tape via `executeAcrossV5Msg`.
     */
    function _transferTokensToRecipientV5(
        V3RelayData memory relayData,
        address submitter,
        uint256 amount,
        bytes memory recipientMsg,
        bytes memory recipientJit,
        uint256 nativeValue
    ) internal {
        address outputToken = relayData.outputToken.toAddress();
        address recipient = relayData.recipient.toAddress();
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

    /// @notice Digest signed by an auction authority to resolve a deposit's output amount.
    function auctionDigest(bytes32 stepId, uint256 fillId, uint256 resolvedOutputAmount) public view returns (bytes32) {
        return keccak256(abi.encodePacked(auctionResolutionDomain, stepId, fillId, resolvedOutputAmount));
    }
}
