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
 * @dev `maxExecutionFee` bounds the dynamic `executionFee` set by the signer at runtime; even a
 *      compromised counterfactual signer cannot authorize a fee above this cap.
 */
struct CCTPRouteParams {
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
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `executionFee` is dynamic and authorized by `counterfactualSignature` (local signer,
 *      independent from the SrcPeriphery's quote signer — see D11). `peripherySignature` continues
 *      to authorize the SponsoredCCTP quote (amount, nonce, cctpDeadline, etc.).
 */
struct CCTPSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    uint32 signatureDeadline;
    bytes peripherySignature;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *
 *      Two independent signatures gate execution:
 *      - `peripherySignature` — verified by SponsoredCCTPSrcPeriphery; binds the bridge-level quote
 *        (amount, nonce, deadline, etc.).
 *      - `counterfactualSignature` — verified here; binds `nonce`, `executionFee`, and
 *        `signatureDeadline`, signed by `signer` (independent from the SrcPeriphery signer).
 *
 *      The local signature binds `nonce` rather than `paramsHash`: the periphery quote signature
 *      commits `(route, nonce)` together, so pinning the local sig to `nonce` transitively pins the
 *      route via the periphery — and gives single-use replay protection for free (once the
 *      periphery consumes the nonce, the local sig is unreplayable).
 *
 *      The EIP-712 domain separator uses `address(this)` (the clone) to prevent cross-clone replay.
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
     * @param signatureDeadline Deadline timestamp for the counterfactual signature.
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
    error MaxExecutionFee();

    /// @notice EIP-712 typehash for the local CCTP execute signature.
    /// @dev Binds `nonce` (transitive route binding via the periphery's quote signature, plus
    ///      single-use replay protection through periphery nonce consumption), `executionFee`
    ///      (dynamic fee), and `signatureDeadline`.
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /// @notice Signer that authorizes counterfactual execution parameters (independent from SrcPeriphery signer).
    address public immutable signer;

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain,
        address _signer
    ) EIP712("CounterfactualDepositCCTP", "v2.0.0") {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `params` is ABI-encoded as `CCTPRouteParams`;
     *      `submitterData` as `CCTPSubmitterData`. Verifies the local signature, enforces
     *      `executionFee <= maxExecutionFee`, then forwards the quote (and the periphery
     *      signature) to the SrcPeriphery. ERC-20 only.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPRouteParams memory rp = abi.decode(params, (CCTPRouteParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        if (sd.executionFee > rp.maxExecutionFee) revert MaxExecutionFee();
        _verifyCounterfactualSignature(sd);

        address inputToken = address(uint160(uint256(rp.burnToken)));

        if (sd.executionFee > 0) IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(rp, sd, depositAmount);

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
     * @param rp Route parameters from the merkle leaf.
     * @param sd Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _depositForBurn(CCTPRouteParams memory rp, CCTPSubmitterData memory sd, uint256 depositAmount) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: rp.destinationDomain,
                mintRecipient: rp.mintRecipient,
                amount: depositAmount,
                burnToken: rp.burnToken,
                destinationCaller: rp.destinationCaller,
                maxFee: (depositAmount * rp.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: rp.minFinalityThreshold,
                nonce: sd.nonce,
                deadline: sd.cctpDeadline,
                maxBpsToSponsor: rp.maxBpsToSponsor,
                maxUserSlippageBps: rp.maxUserSlippageBps,
                finalRecipient: rp.finalRecipient,
                finalToken: rp.finalToken,
                destinationDex: rp.destinationDex,
                accountCreationMode: rp.accountCreationMode,
                executionMode: rp.executionMode,
                actionData: rp.actionData
            }),
            sd.peripherySignature
        );
    }

    function _verifyCounterfactualSignature(CCTPSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_CCTP_TYPEHASH, sd.nonce, sd.executionFee, sd.signatureDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.counterfactualSignature) != signer)
            revert InvalidSignature();
    }
}
