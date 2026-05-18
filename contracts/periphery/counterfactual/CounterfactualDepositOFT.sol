// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `executionFee` is intentionally NOT in this struct — it is supplied at execute time in
 *      `OFTSubmitterData` and authorized by a local signer EIP-712 signature. `maxExecutionFeeBps`
 *      bounds the runtime fee against the amount being bridged.
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
    uint256 maxExecutionFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `signature` is the SponsoredOFTSrcPeriphery quote signature (validated by the periphery).
 *      `executionFeeSignature` is a local EIP-712 signature from this impl's `signer` over the dynamic
 *      `executionFee`. Both must validate.
 */
struct OFTSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    bytes signature;
    uint256 executionFeeDeadline;
    bytes executionFeeSignature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *      msg.value covers LayerZero native messaging fees.
 *
 *      Two signatures are verified per execute:
 *        1. The periphery's quote signature (validated by `SponsoredOFTSrcPeriphery`).
 *        2. A local EIP-712 signature from `signer` binding `keccak256(params)`, the runtime `amount`, the
 *           runtime `executionFee`, and a `deadline`.
 *
 *      Cross-leaf destination consistency is enforced by the merkle root: every leaf's `params` encodes its
 *      destination via `dstEid` + `finalRecipient` + `finalToken`, so the root commits to every destination
 *      the clone can bridge to, and the CREATE2 address itself binds destination identity.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFT is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after an OFT deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Fee paid to the executor at execution time (signer-authorized).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce OFT nonce used for the deposit.
     * @param oftDeadline Deadline timestamp for the OFT quote.
     */
    event OFTDepositExecuted(
        uint256 amount,
        uint256 executionFee,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline
    );

    error InvalidExecutionFeeSignature();
    error ExecutionFeeSignatureExpired();
    error ExecutionFeeTooHigh();

    /// @notice EIP-712 typehash for executionFee signature verification.
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 paramsHash,uint256 amount,uint256 executionFee,uint256 executionFeeDeadline)");

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    /// @notice Signer that authorizes the runtime executionFee
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
     *      `submitterData` as `OFTSubmitterData` (carries the periphery quote signature plus the local
     *      executionFee signature). ERC-20 only. Forwards `msg.value` for LayerZero messaging fees.
     *      Reverts: `ExecutionFeeSignatureExpired`, `InvalidExecutionFeeSignature`, `ExecutionFeeTooHigh`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        OFTDepositParams memory dp = abi.decode(params, (OFTDepositParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        if (block.timestamp > sd.executionFeeDeadline) revert ExecutionFeeSignatureExpired();
        if (sd.executionFee > (sd.amount * dp.maxExecutionFeeBps) / BPS_SCALAR) revert ExecutionFeeTooHigh();
        _verifyExecutionFeeSignature(keccak256(params), sd);

        if (sd.executionFee > 0) IERC20(dp.token).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(dp.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(dp, sd, depositAmount);

        emit OFTDepositExecuted(sd.amount, sd.executionFee, sd.executionFeeRecipient, sd.nonce, sd.oftDeadline);
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
            sd.signature
        );
    }

    function _verifyExecutionFeeSignature(bytes32 paramsHash, OFTSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_OFT_TYPEHASH, paramsHash, sd.amount, sd.executionFee, sd.executionFeeDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.executionFeeSignature) != signer) {
            revert InvalidExecutionFeeSignature();
        }
    }
}
