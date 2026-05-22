// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 */
struct CCTPDepositParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
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
 * @notice Data supplied by the submitter at execution time.
 * @dev `executionFee` and `signatureDeadline` are bound by `implSignature` from the impl-level signer
 *      (independent from the SrcPeriphery's quote signer — see D11). `srcPeripherySignature` continues
 *      to authorize the SponsoredCCTP quote (amount, nonce, cctpDeadline, etc.).
 */
struct CCTPSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    uint32 signatureDeadline;
    bytes srcPeripherySignature;
    bytes implSignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *
 *      Two independent signatures gate execution:
 *      - `srcPeripherySignature` — verified by SponsoredCCTPSrcPeriphery; binds the bridge-level quote
 *        (amount, nonce, deadline, etc.).
 *      - `implSignature` — verified here; binds `paramsHash`, `executionFee`, and `signatureDeadline`,
 *        signed by `signer` (independent from the SrcPeriphery signer).
 *
 *      Binding `paramsHash` prevents cross-leaf signature replay between two CCTP leaves on the same
 *      impl. The EIP-712 domain separator uses `address(this)` (the clone address) to prevent
 *      cross-clone replay.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Execution fee paid to the submitter-chosen recipient.
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce CCTP nonce used for the deposit.
     * @param cctpDeadline Deadline timestamp for the CCTP quote.
     * @param signatureDeadline Deadline timestamp for the impl-level signature.
     */
    event CCTPDepositExecuted(
        uint256 amount,
        uint256 executionFee,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        uint32 signatureDeadline
    );

    error InvalidSignature();
    error SignatureExpired();

    /// @notice EIP-712 typehash for the impl-level CCTP execute signature.
    /// @dev The SrcPeriphery signature already binds amount/nonce/cctpDeadline; the impl-level
    ///      signature adds `paramsHash` (cross-leaf safety) and `executionFee` (dynamic fee) under
    ///      a deadline distinct from the bridge quote's deadline.
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTPDeposit(bytes32 paramsHash,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /// @notice Signer that authorizes impl-level execution parameters (independent from SrcPeriphery signer).
    address public immutable signer;

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain,
        address _signer
    ) EIP712("CounterfactualDepositCCTP", "v1.0.0") {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `params` is ABI-encoded as `CCTPDepositParams`;
     *      `submitterData` as `CCTPSubmitterData`. Verifies the impl-level signature locally,
     *      then forwards the quote (and the SrcPeriphery signature) to the periphery. ERC-20 only.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifyImplSignature(keccak256(params), sd);

        address inputToken = address(uint160(uint256(dp.burnToken)));

        if (sd.executionFee > 0) IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(dp, sd, depositAmount);

        emit CCTPDepositExecuted(
            sd.amount,
            sd.executionFee,
            sd.executionFeeRecipient,
            sd.nonce,
            sd.cctpDeadline,
            sd.signatureDeadline
        );
    }

    /**
     * @notice Calls depositForBurn on the SponsoredCCTPSrcPeriphery with the constructed quote.
     * @param dp Route parameters from the merkle leaf.
     * @param sd Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _depositForBurn(CCTPDepositParams memory dp, CCTPSubmitterData memory sd, uint256 depositAmount) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: dp.destinationDomain,
                mintRecipient: dp.mintRecipient,
                amount: depositAmount,
                burnToken: dp.burnToken,
                destinationCaller: dp.destinationCaller,
                maxFee: (depositAmount * dp.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: dp.minFinalityThreshold,
                nonce: sd.nonce,
                deadline: sd.cctpDeadline,
                maxBpsToSponsor: dp.maxBpsToSponsor,
                maxUserSlippageBps: dp.maxUserSlippageBps,
                finalRecipient: dp.finalRecipient,
                finalToken: dp.finalToken,
                destinationDex: dp.destinationDex,
                accountCreationMode: dp.accountCreationMode,
                executionMode: dp.executionMode,
                actionData: dp.actionData
            }),
            sd.srcPeripherySignature
        );
    }

    function _verifyImplSignature(bytes32 paramsHash, CCTPSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_CCTP_TYPEHASH, paramsHash, sd.executionFee, sd.signatureDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.implSignature) != signer) revert InvalidSignature();
    }
}
