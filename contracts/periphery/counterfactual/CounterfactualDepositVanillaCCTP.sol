// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ITokenMessengerV2 } from "../../external/interfaces/CCTPInterfaces.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `hookData` selects the CCTP entrypoint: empty ⇒ `depositForBurn` (plain CCTP, USDC mints to
 *      `mintRecipient`); non-empty ⇒ `depositForBurnWithHook` (e.g. HyperCore, where `mintRecipient` is
 *      Circle's `CctpForwarder` and `hookData` is its envelope encoding the HyperCore recipient — both
 *      opaque here and built off-chain into the leaf). `cctpMaxFeeBps`/`minFinalityThreshold` choose the
 *      fast vs standard transfer (standard ⇒ `cctpMaxFeeBps = 0`).
 */
struct VanillaCCTPRouteParams {
    uint256 sourceChainId;
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    bytes hookData;
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct VanillaCCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    uint256 executionFee;
    uint32 signatureDeadline;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositVanillaCCTP
 * @notice Implementation contract for counterfactual deposits via vanilla (non-sponsored) Circle CCTP v2.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher, so `address(this)` is the
 *      counterfactual proxy (it holds the funds and is the EIP-712 `verifyingContract`) and `msg.sender`
 *      is the original caller. Unlike `CounterfactualDepositCCTP`, this calls Circle's `ITokenMessengerV2`
 *      directly — there is no Across periphery and no sponsored destination machinery: USDC mints natively
 *      on the destination. An empty `hookData` uses `depositForBurn` (plain CCTP); a non-empty `hookData`
 *      uses `depositForBurnWithHook` (e.g. HyperCore via Circle's `CctpForwarder`).
 *
 *      Because there is no periphery quote signature to bind the route/amount, the local EIP-712 fee
 *      signature binds the full route (`routeParamsHash`), the `amount`, the `executionFee`, and a
 *      `signatureDeadline`, and resolves `verifyingContract` to this proxy. Replay protection is the short
 *      `signatureDeadline` (no nonce). ERC-20 only (no native tokens).
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositVanillaCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a vanilla CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param executionFee Execution fee paid to the executor (in input token).
     * @param depositAmount Amount burned via CCTP (`amount - executionFee`).
     */
    event VanillaCCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        uint256 executionFee,
        uint256 depositAmount
    );

    error InvalidSignature();
    error SignatureExpired();
    error MaxExecutionFee();
    error SourceChainMismatch();

    /// @notice EIP-712 typehash binding the fee signature to the route, amount, runtime fee, and deadline.
    bytes32 public constant EXECUTE_VANILLA_CCTP_TYPEHASH =
        keccak256(
            "ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint32 signatureDeadline)"
        );

    /// @notice Circle CCTP v2 TokenMessenger (immutable, same for all deposits on this chain).
    ITokenMessengerV2 public immutable tokenMessenger;

    /// @notice CCTP source domain ID for this chain.
    uint32 public immutable sourceDomain;

    /// @notice Signer that authorizes the runtime execution fee (and, here, the route + amount).
    address public immutable signer;

    constructor(
        address _tokenMessenger,
        uint32 _sourceDomain,
        address _signer
    ) EIP712("CounterfactualDepositVanillaCCTP", "v2.0.0") {
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via Circle CCTP v2. `routeParamsEncoded` is ABI-encoded as `VanillaCCTPRouteParams`;
     *      `submitterDataEncoded` as `VanillaCCTPSubmitterData`. ERC-20 only.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        VanillaCCTPRouteParams memory routeParams = abi.decode(routeParamsEncoded, (VanillaCCTPRouteParams));
        VanillaCCTPSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (VanillaCCTPSubmitterData));

        if (block.chainid != routeParams.sourceChainId) revert SourceChainMismatch();
        // Binds the exact merkle leaf (`keccak256(params)` is the leaf's params component), the amount, and
        // the fee — the sole authorization of this transfer, since there is no periphery quote signature.
        _verifySignature(keccak256(routeParamsEncoded), submitterData);
        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        address inputToken = address(uint160(uint256(routeParams.burnToken)));

        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;
        uint256 maxFee = (depositAmount * routeParams.cctpMaxFeeBps) / BPS_SCALAR;

        IERC20(inputToken).forceApprove(address(tokenMessenger), depositAmount);

        // Non-empty hookData routes through depositForBurnWithHook (HyperCore via Circle's CctpForwarder,
        // or any hook-aware destination); empty hookData is a plain native CCTP mint to `mintRecipient`.
        if (routeParams.hookData.length > 0) {
            tokenMessenger.depositForBurnWithHook(
                depositAmount,
                routeParams.destinationDomain,
                routeParams.mintRecipient,
                inputToken,
                routeParams.destinationCaller,
                maxFee,
                routeParams.minFinalityThreshold,
                routeParams.hookData
            );
        } else {
            tokenMessenger.depositForBurn(
                depositAmount,
                routeParams.destinationDomain,
                routeParams.mintRecipient,
                inputToken,
                routeParams.destinationCaller,
                maxFee,
                routeParams.minFinalityThreshold
            );
        }

        emit VanillaCCTPDepositExecuted(
            submitterData.amount,
            submitterData.executionFeeRecipient,
            submitterData.executionFee,
            depositAmount
        );
    }

    function _verifySignature(bytes32 routeParamsHash, VanillaCCTPSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_VANILLA_CCTP_TYPEHASH,
                routeParamsHash,
                submitterData.amount,
                submitterData.executionFee,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != signer)
            revert InvalidSignature();
    }
}
