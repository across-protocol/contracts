// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev Chain-agnostic: it names no source chain and no token address. The input token is named indirectly
 *      by `inputTokenGetter` — the 4-byte selector of the beacon getter that resolves the per-chain token
 *      address (e.g. `CounterfactualBeacon.usdc.selector`). "Native" is not a special selector: the leaf
 *      always resolves the getter, and the returned address itself signals native (the well-known sentinel
 *      `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) vs ERC-20. The same leaf can name e.g.
 *      `beacon.nativeToken.selector` and behave as a native deposit on chains where the beacon returns the
 *      sentinel and as an ERC-20 deposit on chains where the beacon returns a token address.
 *      `destinationChainId`, `outputToken` and `recipient` are the (chain-invariant) destination identity.
 */
struct SpokePoolRouteParams {
    bytes4 inputTokenGetter;
    uint256 destinationChainId;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    bool checkStableExchangeRate;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct SpokePoolSubmitterData {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    uint256 executionFee;
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation for counterfactual deposits via Across SpokePool, agnostic to the input token.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. The SpokePool, wrapped native
 *      token and fee signer are resolved from the `CounterfactualBeacon` at runtime; the input token is
 *      resolved from whichever beacon getter the leaf's `inputTokenGetter` selector names. Native vs ERC-20
 *      is decided by the resolved value (`NATIVE_SENTINEL` ⇒ msg.value path, SpokePool input is
 *      `beacon.wrappedNativeToken()`; otherwise ⇒ ERC-20 transferFrom path). This decouples the leaf from
 *      whether a given chain's "native route" actually has a native gas token, so this implementation
 *      holds no chain-specific values, has one address on every chain, and a single leaf works everywhere
 *      (see `CounterfactualImplementationBase`).
 *
 *      No per-token implementation variants and no per-variant EIP-712 names are needed: `inputTokenGetter`
 *      is part of `params`, so it is committed in `routeParamsHash` — which this contract's EIP-712 fee
 *      signature binds — meaning a signature for one token never validates for another. Cross-chain replay
 *      is independently prevented by the `chainId` in the EIP-712 domain, and cross-clone replay by
 *      `verifyingContract = address(this)` (the clone). No nonce is needed: token balance is consumed on
 *      execution (natural replay protection), and short deadlines bound the window. Depositor-driven
 *      speed-ups are not supported: the `depositor` passed to `SpokePool.deposit()` is `address(this)` (the
 *      clone), which has no private key and does not implement EIP-1271.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is CounterfactualImplementationBase, EIP712, SafeTransferERC20 {
    // Restrict the `using` attachment to `forceApprove` only. All `safeTransfer` calls must go
    // through the `_safeTransfer` hook (inherited from `SafeTransferERC20`) so chain-specific
    // variants can override transfer semantics in one place.
    using { SafeERC20.forceApprove } for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /// @notice Well-known sentinel address that signals "treat this route as native" when returned by the
    ///         beacon getter named in `inputTokenGetter`. Same value used by Aave/Compound/many bridges to
    ///         stand in for the native gas token at an address-typed slot.
    address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     * @notice Emitted after a SpokePool deposit is successfully executed.
     * @param inputAmount Total input amount (including execution fee).
     * @param outputAmount Output amount on the destination chain.
     * @param exclusiveRelayer Address of the exclusive relayer (bytes32-encoded).
     * @param exclusivityDeadline Timestamp until which the exclusive relayer has priority.
     * @param executionFeeRecipient Address that received the execution fee.
     * @param quoteTimestamp Timestamp of the deposit quote.
     * @param fillDeadline Deadline by which the deposit must be filled.
     * @param signatureDeadline Deadline after which the authorizing signature expires.
     * @param executionFee Execution fee paid to the executor (in input token).
     */
    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 indexed exclusiveRelayer,
        uint32 exclusivityDeadline,
        address indexed executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        uint256 executionFee
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();
    error NativeTransferFailed();

    /// @notice EIP-712 typehash for execute deposit signature verification.
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    constructor() EIP712("CounterfactualDepositSpokePool", "v2.0.0") {} // solhint-disable-line no-empty-blocks

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Deposits into the Across SpokePool. `routeParamsEncoded` is ABI-encoded as `SpokePoolRouteParams`;
     *      `submitterDataEncoded` as `SpokePoolSubmitterData` (includes an EIP-712 signature from the beacon's
     *      `signer`). Native vs ERC-20 is decided by the value resolved from `inputTokenGetter`:
     *      `NATIVE_SENTINEL` ⇒ native (msg.value); any other address ⇒ ERC-20. Reverts: `SignatureExpired`,
     *      `InvalidSignature`, `MaxFee`, `NativeTransferFailed`, `RouteNotConfigured`.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        SpokePoolRouteParams memory routeParams = abi.decode(routeParamsEncoded, (SpokePoolRouteParams));
        SpokePoolSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (SpokePoolSubmitterData));

        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        _verifySignature(keccak256(routeParamsEncoded), submitterData);

        uint256 depositAmount = submitterData.inputAmount - submitterData.executionFee;
        _checkFee(
            routeParams,
            submitterData.inputAmount,
            submitterData.outputAmount,
            depositAmount,
            submitterData.executionFee
        );

        ICounterfactualBeacon beacon = _beacon();
        address spokePool = _requireConfigured(beacon.spokePool());

        // The leaf names a regular beacon getter; the chain's beacon decides whether this route is paid
        // in native (returns `NATIVE_SENTINEL`) or in an ERC-20 (returns the token address). Branching on
        // the value — not on the selector — lets the same merkle leaf serve both flavors.
        address resolved = _requireConfigured(_resolveInputToken(beacon, routeParams.inputTokenGetter));
        bool isNative = resolved == NATIVE_SENTINEL;
        address inputToken; // ERC-20 to approve/sweep (unused for native)
        bytes32 spokePoolInputToken;
        if (isNative) {
            spokePoolInputToken = bytes32(uint256(uint160(_requireConfigured(beacon.wrappedNativeToken()))));
        } else {
            inputToken = resolved;
            IERC20(inputToken).forceApprove(spokePool, depositAmount);
            spokePoolInputToken = bytes32(uint256(uint160(inputToken)));
        }

        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            routeParams.recipient,
            spokePoolInputToken,
            routeParams.outputToken,
            depositAmount,
            submitterData.outputAmount,
            routeParams.destinationChainId,
            submitterData.exclusiveRelayer,
            submitterData.quoteTimestamp,
            submitterData.fillDeadline,
            submitterData.exclusivityDeadline,
            routeParams.message
        );

        // Pay execution fee
        if (submitterData.executionFee > 0) {
            if (isNative) {
                (bool success, ) = submitterData.executionFeeRecipient.call{ value: submitterData.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                _safeTransfer(inputToken, submitterData.executionFeeRecipient, submitterData.executionFee);
            }
        }

        emit SpokePoolDepositExecuted(
            submitterData.inputAmount,
            submitterData.outputAmount,
            submitterData.exclusiveRelayer,
            submitterData.exclusivityDeadline,
            submitterData.executionFeeRecipient,
            submitterData.quoteTimestamp,
            submitterData.fillDeadline,
            submitterData.signatureDeadline,
            submitterData.executionFee
        );
    }

    /// @dev Resolve the input token by calling the beacon getter named by `getter` (a no-arg `() -> address`
    ///      selector, e.g. `usdc()`). A failed call or non-address return yields `address(0)`, which the
    ///      caller treats as `RouteNotConfigured`. The selector is committed in the merkle leaf and bound by
    ///      the fee signature, so it is trusted input; a malformed selector can only revert here or downstream.
    function _resolveInputToken(ICounterfactualBeacon beacon, bytes4 getter) private view returns (address) {
        (bool ok, bytes memory ret) = address(beacon).staticcall(abi.encodeWithSelector(getter));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _checkFee(
        SpokePoolRouteParams memory routeParams,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 depositAmount,
        uint256 executionFee
    ) private pure {
        // When `checkStableExchangeRate` is false (e.g. non-stable pairs), the rate-derived relayer fee
        // is not enforced — `outputAmount` is trusted via the signer's signature — but `executionFee`
        // remains bounded by `maxFee` below.
        uint256 relayerFee;
        if (routeParams.checkStableExchangeRate) {
            uint256 outputInInputToken = (outputAmount * routeParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
            relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        }
        uint256 totalFee = relayerFee + executionFee;
        uint256 maxFee = routeParams.maxFeeFixed + (routeParams.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(bytes32 routeParamsHash, SpokePoolSubmitterData memory submitterData) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                address(this),
                routeParamsHash,
                submitterData.inputAmount,
                submitterData.outputAmount,
                submitterData.exclusiveRelayer,
                submitterData.exclusivityDeadline,
                submitterData.quoteTimestamp,
                submitterData.fillDeadline,
                submitterData.signatureDeadline,
                submitterData.executionFee
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.signature) != _beacon().signer())
            revert InvalidSignature();
    }
}
