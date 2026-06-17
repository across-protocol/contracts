// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import { SpokePool } from "./SpokePool.sol";
import { Bytes32ToAddress } from "../libraries/AddressConverters.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";

// V5 executor interface (the renamed `IExecutor`). The Gateway calls this on its `executor`; recipients implement
// it to run a command tape after receiving funds.
interface IAcrossV5Executor {
    function executeAcrossV5Msg(bytes calldata userMsg, bytes calldata submitterMsg) external payable;
}

// Minimal view of the V5 Gateway execution context. `currentStepId()` is assumed to be exposed by the V5 Gateway.
interface IAcrossV5Gateway {
    function currentSubmitter() external view returns (address submitter);

    function currentStepId() external view returns (bytes32 stepId);
}

/**
 * @title SpokePoolV5
 * @notice Lets a SpokePool act directly as a V5 `executor`, collapsing the deposit/fill token flow to the fewest
 * transfers. V5 messages are tagged MAGIC_ACXV5_MESSAGE_PREFIX so a V5 Filled event can only come from this path.
 * @dev OPEN/PROPOSED: the `userMsg`/`submitterMsg` encodings are a proposal; the Gateway must call
 * `executeAcrossV5Msg` and expose `currentStepId()`; chain variants extend this and pass `gateway` to the ctor.
 */
abstract contract SpokePoolV5 is SpokePool, IAcrossV5Executor {
    using { SafeERC20Upgradeable.safeTransferFrom } for IERC20Upgradeable;
    using Bytes32ToAddress for bytes32;

    // V5 Gateway permitted to drive `executeAcrossV5Msg`.
    address public immutable gateway;

    // Domain separator binding auction-authority signatures to this Gateway instance.
    bytes32 public immutable auctionResolutionDomain;

    // userMsg action selector, carried as the first raw byte of userMsg (the payload follows from byte 1).
    uint8 internal constant ACXV5_ACTION_FILL = 1;
    uint8 internal constant ACXV5_ACTION_DEPOSIT = 2;

    bytes32 internal constant ACXV5_AUCTION_NAMEHASH = keccak256("ACXV5.SpokePool.AuctionResolution.V1");

    error NotGateway();
    error InvalidV5Action();
    error WitnessMismatch();
    error OutputBelowMinimum(uint256 minimumOutputAmount, uint256 resolvedOutputAmount);
    error InvalidAuctionSignature(address authority);

    // User-committed fill payload: V3RelayData minus `message`. `outputAmount` is the floor that is emitted and
    // repaid; the submitter may deliver more (see `_fillV5`).
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

    // User-committed deposit payload. `outputAmount` is the floor; the resolved amount must be >= it.
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
        address auctionAuthority; // if non-zero: auction mode, this signer authorizes the resolved amount
        uint256 fillId; // disambiguates deposits/auctions for the same origin step
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

    // V5 executor entry point; only the Gateway may call. userMsg[0] selects the action, userMsg[1:] is the payload;
    // submitterMsg carries submitter JIT data.
    function executeAcrossV5Msg(bytes calldata userMsg, bytes calldata submitterMsg) external payable override {
        if (msg.sender != gateway) revert NotGateway();
        // Funds backing this execution come from the Gateway submitter.
        address submitter = IAcrossV5Gateway(gateway).currentSubmitter();

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

    // Lock a V5 deposit funded by the submitter. Unsafe deposit id is derived from origin stepId + fillId; output is
    // submitter-resolved (>= floor) and, when auctionAuthority is set, authority-signed.
    function _depositV5Unsafe(bytes calldata userMsg, bytes calldata submitterMsg, address submitter) internal {
        if (pausedDeposits) revert DepositsArePaused();

        AcrossV5DepositData memory d = abi.decode(userMsg, (AcrossV5DepositData));
        bytes32 originStepId = IAcrossV5Gateway(gateway).currentStepId();

        // Submitter resolves the output amount; auction mode also carries the authority signature.
        (uint256 resolvedOutputAmount, bytes memory signature) = abi.decode(submitterMsg, (uint256, bytes));
        if (resolvedOutputAmount < d.outputAmount) revert OutputBelowMinimum(d.outputAmount, resolvedOutputAmount);

        // Auction mode: the resolved amount must be authorized by the committed authority.
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

    // Fill a V5 deposit. Message is MAGIC || witness (matches the origin deposit, validated against the live step);
    // submitter may over-deliver to sponsor the recipient's tape while the emitted/repaid amount stays the floor.
    function _fillV5(
        bytes calldata userMsg,
        bytes calldata submitterMsg,
        address submitter,
        uint256 nativeValue
    ) internal {
        if (pausedFills) revert FillsArePaused();

        (AcrossV5FillData memory f, bytes memory recipientMsg) = abi.decode(userMsg, (AcrossV5FillData, bytes));

        // Submitter JIT: witness, repayment routing (not in the relay hash), over-delivery amount, and tape JIT.
        (
            bytes32 witness,
            uint256 repaymentChainId,
            bytes32 repaymentAddress,
            uint256 resolvedOutputAmount,
            bytes memory recipientJit
        ) = abi.decode(submitterMsg, (bytes32, uint256, bytes32, uint256, bytes));

        if (witness == bytes32(0) || witness != IAcrossV5Gateway(gateway).currentStepId()) revert WitnessMismatch();

        // Over-delivery (>= floor) lets the submitter sponsor the recipient's tape.
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

        // updatedOutputAmount is what's delivered; relay.outputAmount (hashed and repaid) stays the committed floor.
        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: getV3RelayHash(relayData),
            updatedOutputAmount: resolvedOutputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: repaymentChainId
        });

        // Shared pipeline: deadline + exclusivity (vs the submitter) + status dedup + standard FilledRelay event.
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

    // Send the output token to the recipient, then run its tape if present. Native (wrapped) output is unwrapped for
    // tape-less fills; otherwise the token is transferred straight through.
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
            // Native: pull wrapped to self, unwrap, send native to the recipient.
            IERC20Upgradeable(outputToken).safeTransferFrom(submitter, address(this), amount);
            _unwrapwrappedNativeTokenTo(payable(recipient), amount);
        } else {
            // Single transfer: submitter -> recipient.
            IERC20Upgradeable(outputToken).safeTransferFrom(submitter, recipient, amount);
        }

        if (hasTape) {
            IAcrossV5Executor(recipient).executeAcrossV5Msg{ value: nativeValue }(recipientMsg, recipientJit);
        }
    }

    // Digest signed by an auction authority to resolve a deposit's output amount (bound to this Gateway instance).
    function auctionDigest(bytes32 stepId, uint256 fillId, uint256 resolvedOutputAmount) public view returns (bytes32) {
        return keccak256(abi.encodePacked(auctionResolutionDomain, stepId, fillId, resolvedOutputAmount));
    }
}
