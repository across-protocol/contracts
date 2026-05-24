// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `maxExecutionFee` bounds the dynamic `executionFee` set by the signer at runtime; even a
 *      compromised counterfactual signer cannot authorize a fee above this cap.
 */
struct OFTRouteParams {
    uint32 dstEid;
    bytes32 destinationHandler;
    address token;
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
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `executionFee` is dynamic and authorized by `counterfactualSignature` (local signer,
 *      independent from the SrcPeriphery's quote signer — see D11). `peripherySignature` continues
 *      to authorize the SponsoredOFT quote (amount, nonce, oftDeadline, etc.).
 */
struct OFTSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    uint32 signatureDeadline;
    bytes peripherySignature;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT (LayerZero).
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *      `msg.value` covers LayerZero native messaging fees, forwarded to the SrcPeriphery.
 *
 *      Two independent signatures gate execution:
 *      - `peripherySignature` — verified by SponsoredOFTSrcPeriphery; binds the bridge-level quote.
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
contract CounterfactualDepositOFT is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after an OFT deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Execution fee paid to the submitter-chosen recipient.
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce OFT nonce used for the deposit.
     * @param oftDeadline Deadline timestamp for the OFT quote.
     * @param signatureDeadline Deadline timestamp for the counterfactual signature.
     */
    event OFTDepositExecuted(
        uint256 amount,
        uint256 executionFee,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        uint32 signatureDeadline
    );

    error InvalidSignature();
    error SignatureExpired();
    error MaxExecutionFee();

    /// @notice EIP-712 typehash for the local OFT execute signature.
    /// @dev Binds `nonce` (transitive route binding via the periphery's quote signature, plus
    ///      single-use replay protection through periphery nonce consumption), `executionFee`
    ///      (dynamic fee), and `signatureDeadline`.
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    /// @notice Signer that authorizes counterfactual execution parameters (independent from SrcPeriphery signer).
    address public immutable signer;

    constructor(
        address _oftSrcPeriphery,
        uint32 _srcEid,
        address _signer
    ) EIP712("CounterfactualDepositOFT", "v2.0.0") {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `params` is ABI-encoded as `OFTRouteParams`;
     *      `submitterData` as `OFTSubmitterData`. Verifies the local signature, enforces
     *      `executionFee <= maxExecutionFee`, then forwards the quote (and the periphery
     *      signature) to the SrcPeriphery. ERC-20 only. Forwards `msg.value` for LayerZero
     *      messaging fees.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        OFTRouteParams memory rp = abi.decode(params, (OFTRouteParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        if (sd.executionFee > rp.maxExecutionFee) revert MaxExecutionFee();
        _verifyCounterfactualSignature(sd);

        if (sd.executionFee > 0) IERC20(rp.token).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(rp.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(rp, sd, depositAmount);

        emit OFTDepositExecuted(
            sd.amount,
            sd.executionFee,
            sd.executionFeeRecipient,
            sd.nonce,
            sd.oftDeadline,
            sd.signatureDeadline
        );
    }

    /**
     * @notice Calls deposit on the SponsoredOFTSrcPeriphery with the constructed quote.
     * @param rp Route parameters from the merkle leaf.
     * @param sd Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _deposit(OFTRouteParams memory rp, OFTSubmitterData memory sd, uint256 depositAmount) private {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: rp.dstEid,
                    destinationHandler: rp.destinationHandler,
                    amountLD: depositAmount,
                    nonce: sd.nonce,
                    deadline: sd.oftDeadline,
                    maxBpsToSponsor: rp.maxBpsToSponsor,
                    maxUserSlippageBps: rp.maxUserSlippageBps,
                    finalRecipient: rp.finalRecipient,
                    finalToken: rp.finalToken,
                    destinationDex: rp.destinationDex,
                    lzReceiveGasLimit: rp.lzReceiveGasLimit,
                    lzComposeGasLimit: rp.lzComposeGasLimit,
                    maxOftFeeBps: rp.maxOftFeeBps,
                    accountCreationMode: rp.accountCreationMode,
                    executionMode: rp.executionMode,
                    actionData: rp.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: rp.refundRecipient })
            }),
            sd.peripherySignature
        );
    }

    function _verifyCounterfactualSignature(OFTSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_OFT_TYPEHASH, sd.nonce, sd.executionFee, sd.signatureDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.counterfactualSignature) != signer)
            revert InvalidSignature();
    }
}
