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
 */
struct OFTDepositParams {
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
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `executionFee` and `signatureDeadline` are bound by `implSignature` from the impl-level signer
 *      (independent from the SrcPeriphery's quote signer — see D11). `srcPeripherySignature` continues
 *      to authorize the SponsoredOFT quote (amount, nonce, oftDeadline, etc.).
 */
struct OFTSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    uint32 signatureDeadline;
    bytes srcPeripherySignature;
    bytes implSignature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT (LayerZero).
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *      `msg.value` covers LayerZero native messaging fees, forwarded to the SrcPeriphery.
 *
 *      Two independent signatures gate execution:
 *      - `srcPeripherySignature` — verified by SponsoredOFTSrcPeriphery; binds the bridge-level quote.
 *      - `implSignature` — verified here; binds `paramsHash`, `executionFee`, and `signatureDeadline`,
 *        signed by `signer` (independent from the SrcPeriphery signer).
 *
 *      Binding `paramsHash` prevents cross-leaf signature replay between two OFT leaves on the same
 *      impl. The EIP-712 domain separator uses `address(this)` (the clone address) to prevent
 *      cross-clone replay.
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
     * @param signatureDeadline Deadline timestamp for the impl-level signature.
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

    /// @notice EIP-712 typehash for the impl-level OFT execute signature.
    /// @dev The SrcPeriphery signature already binds amount/nonce/oftDeadline; the impl-level
    ///      signature adds `paramsHash` (cross-leaf safety) and `executionFee` (dynamic fee) under
    ///      a deadline distinct from the bridge quote's deadline.
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFTDeposit(bytes32 paramsHash,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    /// @notice Signer that authorizes impl-level execution parameters (independent from SrcPeriphery signer).
    address public immutable signer;

    constructor(
        address _oftSrcPeriphery,
        uint32 _srcEid,
        address _signer
    ) EIP712("CounterfactualDepositOFT", "v1.0.0") {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `params` is ABI-encoded as `OFTDepositParams`;
     *      `submitterData` as `OFTSubmitterData`. Verifies the impl-level signature locally, then
     *      forwards the quote (and the SrcPeriphery signature) to the periphery. ERC-20 only.
     *      Forwards `msg.value` for LayerZero messaging fees.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        OFTDepositParams memory dp = abi.decode(params, (OFTDepositParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifyImplSignature(keccak256(params), sd);

        if (sd.executionFee > 0) IERC20(dp.token).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(dp.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(dp, sd, depositAmount);

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
     * @param dp Route parameters from the merkle leaf.
     * @param sd Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _deposit(OFTDepositParams memory dp, OFTSubmitterData memory sd, uint256 depositAmount) private {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: dp.dstEid,
                    destinationHandler: dp.destinationHandler,
                    amountLD: depositAmount,
                    nonce: sd.nonce,
                    deadline: sd.oftDeadline,
                    maxBpsToSponsor: dp.maxBpsToSponsor,
                    maxUserSlippageBps: dp.maxUserSlippageBps,
                    finalRecipient: dp.finalRecipient,
                    finalToken: dp.finalToken,
                    destinationDex: dp.destinationDex,
                    lzReceiveGasLimit: dp.lzReceiveGasLimit,
                    lzComposeGasLimit: dp.lzComposeGasLimit,
                    maxOftFeeBps: dp.maxOftFeeBps,
                    accountCreationMode: dp.accountCreationMode,
                    executionMode: dp.executionMode,
                    actionData: dp.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: dp.refundRecipient })
            }),
            sd.srcPeripherySignature
        );
    }

    function _verifyImplSignature(bytes32 paramsHash, OFTSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_OFT_TYPEHASH, paramsHash, sd.executionFee, sd.signatureDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.implSignature) != signer) revert InvalidSignature();
    }
}
