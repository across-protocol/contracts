// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

interface ICounterfactualCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

interface ICounterfactualOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Common parameters stored as a hash in the clone's immutable args.
 * @dev Includes the input token, execution fee, withdraw addresses, and a sub-hash for each
 *      supported bridging route. A bytes32(0) route hash means that route is disabled.
 */
struct CounterfactualDepositParams {
    address inputToken;
    uint256 executionFee;
    address userWithdrawAddress;
    address adminWithdrawAddress;
    bytes32 spokePoolRouteHash; // keccak256(abi.encode(SpokePoolRoute)) or bytes32(0)
    bytes32 cctpRouteHash; // keccak256(abi.encode(CCTPRoute)) or bytes32(0)
    bytes32 oftRouteHash; // keccak256(abi.encode(OFTRoute)) or bytes32(0)
}

/**
 * @notice SpokePool-specific route parameters.
 */
struct SpokePoolRoute {
    uint256 destinationChainId;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
}

/**
 * @notice CCTP-specific route parameters.
 */
struct CCTPRoute {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes actionData;
}

/**
 * @notice OFT (LayerZero)-specific route parameters.
 */
struct OFTRoute {
    uint32 dstEid;
    bytes32 destinationHandler;
    uint256 maxOftFeeBps;
    uint256 lzReceiveGasLimit;
    uint256 lzComposeGasLimit;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    address refundRecipient;
    bytes actionData;
}

/**
 * @title CounterfactualDeposit
 * @notice Unified implementation for counterfactual deposits supporting SpokePool, CCTP, and OFT bridging.
 * @dev Deployed as EIP-1167 clones via CounterfactualDepositFactory. Each clone stores a single paramsHash
 *      (keccak256 of CounterfactualDepositParams) in its immutable args. The params struct includes sub-hashes
 *      for each bridging route, allowing the signer to choose the bridging method at execution time while the
 *      counterfactual address remains the same.
 */
contract CounterfactualDeposit is CounterfactualDepositBase, EIP712 {
    using SafeERC20 for IERC20;

    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    );

    event CCTPDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 cctpDeadline);

    event OFTDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 oftDeadline);

    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );

    // SpokePool
    address public immutable spokePool;
    address public immutable signer;
    address public immutable wrappedNativeToken;

    // CCTP
    address public immutable cctpSrcPeriphery;
    uint32 public immutable cctpSourceDomain;

    // OFT
    address public immutable oftSrcPeriphery;
    uint32 public immutable oftSrcEid;

    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken,
        address _cctpSrcPeriphery,
        uint32 _cctpSourceDomain,
        address _oftSrcPeriphery,
        uint32 _oftSrcEid
    ) EIP712("CounterfactualDeposit", "v1.0.0") {
        spokePool = _spokePool;
        signer = _signer;
        wrappedNativeToken = _wrappedNativeToken;
        cctpSrcPeriphery = _cctpSrcPeriphery;
        cctpSourceDomain = _cctpSourceDomain;
        oftSrcPeriphery = _oftSrcPeriphery;
        oftSrcEid = _oftSrcEid;
    }

    receive() external payable {}

    // ─── SpokePool ──────────────────────────────────────────────────────

    /**
     * @notice Executes a deposit via Across SpokePool.
     * @param params Common parameters (verified against stored hash).
     * @param route SpokePool-specific route parameters (verified against params.spokePoolRouteHash).
     * @param inputAmount Gross amount of inputToken (includes executionFee).
     * @param outputAmount Amount of outputToken user should receive on destination.
     * @param exclusiveRelayer Optional exclusive relayer (bytes32(0) for none).
     * @param exclusivityDeadline Seconds of relayer exclusivity (0 for none).
     * @param executionFeeRecipient Address that receives the execution fee.
     * @param quoteTimestamp Quote timestamp from Across API.
     * @param fillDeadline Timestamp by which the deposit must be filled.
     * @param signatureDeadline Timestamp after which the signature is invalid.
     * @param signature EIP-712 signature from signer.
     */
    function executeSpokePoolDeposit(
        CounterfactualDepositParams memory params,
        SpokePoolRoute memory route,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.spokePoolRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(route)) != params.spokePoolRouteHash) revert InvalidRouteHash();
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        _verifySignature(
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signature
        );

        uint256 depositAmount = inputAmount - params.executionFee;

        // Fee check: convert outputAmount to inputToken units, verify total fee within cap
        uint256 outputInInputToken = (outputAmount * route.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + params.executionFee;
        uint256 maxFee = route.maxFeeFixed + (route.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();

        bool isNative = params.inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(params.inputToken).forceApprove(spokePool, depositAmount);

        bytes32 spokePoolInputToken = isNative
            ? bytes32(uint256(uint160(wrappedNativeToken)))
            : bytes32(uint256(uint160(params.inputToken)));
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            route.recipient,
            spokePoolInputToken,
            route.outputToken,
            depositAmount,
            outputAmount,
            route.destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            route.message
        );

        if (params.executionFee > 0) _transferOut(params.inputToken, executionFeeRecipient, params.executionFee);

        emit SpokePoolDepositExecuted(
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            executionFeeRecipient,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline
        );
    }

    // ─── CCTP ───────────────────────────────────────────────────────────

    /**
     * @notice Executes a deposit via SponsoredCCTP.
     * @param params Common parameters (verified against stored hash).
     * @param route CCTP-specific route parameters (verified against params.cctpRouteHash).
     * @param amount Gross amount of burnToken (includes executionFee).
     * @param executionFeeRecipient Address that receives the execution fee.
     * @param nonce Unique nonce for SponsoredCCTP replay protection.
     * @param cctpDeadline Deadline for the SponsoredCCTP quote.
     * @param signature Signature from SponsoredCCTP quote signer.
     */
    function executeCCTPDeposit(
        CounterfactualDepositParams memory params,
        CCTPRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.cctpRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(route)) != params.cctpRouteHash) revert InvalidRouteHash();

        if (params.executionFee > 0) IERC20(params.inputToken).safeTransfer(executionFeeRecipient, params.executionFee);

        uint256 depositAmount = amount - params.executionFee;
        IERC20(params.inputToken).forceApprove(cctpSrcPeriphery, depositAmount);

        ICounterfactualCCTPSrcPeriphery(cctpSrcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: cctpSourceDomain,
                destinationDomain: route.destinationDomain,
                mintRecipient: route.mintRecipient,
                amount: depositAmount,
                burnToken: bytes32(uint256(uint160(params.inputToken))),
                destinationCaller: route.destinationCaller,
                maxFee: (depositAmount * route.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: route.minFinalityThreshold,
                nonce: nonce,
                deadline: cctpDeadline,
                maxBpsToSponsor: route.maxBpsToSponsor,
                maxUserSlippageBps: route.maxUserSlippageBps,
                finalRecipient: route.finalRecipient,
                finalToken: route.finalToken,
                destinationDex: route.destinationDex,
                accountCreationMode: route.accountCreationMode,
                executionMode: route.executionMode,
                actionData: route.actionData
            }),
            signature
        );

        emit CCTPDepositExecuted(amount, executionFeeRecipient, nonce, cctpDeadline);
    }

    // ─── OFT ────────────────────────────────────────────────────────────

    /**
     * @notice Executes a deposit via SponsoredOFT (LayerZero).
     * @dev msg.value covers the LayerZero native messaging fee (paid by executor, not depositor).
     * @param params Common parameters (verified against stored hash).
     * @param route OFT-specific route parameters (verified against params.oftRouteHash).
     * @param amount Gross amount of token (includes executionFee).
     * @param executionFeeRecipient Address that receives the execution fee.
     * @param nonce Unique nonce for SponsoredOFT replay protection.
     * @param oftDeadline Deadline for the SponsoredOFT quote.
     * @param signature Signature from SponsoredOFT quote signer.
     */
    function executeOFTDeposit(
        CounterfactualDepositParams memory params,
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) external payable verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.oftRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(route)) != params.oftRouteHash) revert InvalidRouteHash();

        if (params.executionFee > 0) IERC20(params.inputToken).safeTransfer(executionFeeRecipient, params.executionFee);

        uint256 depositAmount = amount - params.executionFee;
        IERC20(params.inputToken).forceApprove(oftSrcPeriphery, depositAmount);

        ICounterfactualOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: oftSrcEid,
                    dstEid: route.dstEid,
                    destinationHandler: route.destinationHandler,
                    amountLD: depositAmount,
                    nonce: nonce,
                    deadline: oftDeadline,
                    maxBpsToSponsor: route.maxBpsToSponsor,
                    maxUserSlippageBps: route.maxUserSlippageBps,
                    finalRecipient: route.finalRecipient,
                    finalToken: route.finalToken,
                    destinationDex: route.destinationDex,
                    lzReceiveGasLimit: route.lzReceiveGasLimit,
                    lzComposeGasLimit: route.lzComposeGasLimit,
                    maxOftFeeBps: route.maxOftFeeBps,
                    accountCreationMode: route.accountCreationMode,
                    executionMode: route.executionMode,
                    actionData: route.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: route.refundRecipient })
            }),
            signature
        );

        emit OFTDepositExecuted(amount, executionFeeRecipient, nonce, oftDeadline);
    }

    // ─── Withdraw address resolution ────────────────────────────────────

    /// @inheritdoc CounterfactualDepositBase
    function _getUserWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositParams)).userWithdrawAddress;
    }

    /// @inheritdoc CounterfactualDepositBase
    function _getAdminWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositParams)).adminWithdrawAddress;
    }

    // ─── EIP-712 (SpokePool path) ──────────────────────────────────────

    function _verifySignature(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                exclusiveRelayer,
                exclusivityDeadline,
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();
    }
}
