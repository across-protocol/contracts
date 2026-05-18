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
 * @dev `executionFee` is intentionally NOT in this struct — it is supplied at execute time in
 *      `CCTPSubmitterData` and authorized by a local signer EIP-712 signature. `maxExecutionFeeBps`
 *      bounds the runtime fee against the amount being bridged.
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
    uint256 maxExecutionFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `signature` is the SponsoredCCTPSrcPeriphery quote signature (validated by the periphery).
 *      `executionFeeSignature` is a local EIP-712 signature from this impl's `signer` over the dynamic
 *      `executionFee`. Both must validate.
 */
struct CCTPSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    bytes signature;
    uint256 executionFeeDeadline;
    bytes executionFeeSignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *
 *      Two signatures are verified per execute:
 *        1. The periphery's quote signature (validated by `SponsoredCCTPSrcPeriphery`).
 *        2. A local EIP-712 signature from `signer` binding `keccak256(params)`, the runtime `amount`, the
 *           runtime `executionFee`, and a `deadline`. This is what makes `executionFee` safe to supply at
 *           runtime — a malicious executor cannot inflate it without a signer-issued signature.
 *
 *      Cross-leaf destination consistency is enforced by the merkle root: every leaf's `params` encodes its
 *      destination via `destinationDomain` + `finalRecipient` + `finalToken`, so the root commits to every
 *      destination the clone can bridge to, and the CREATE2 address itself binds destination identity.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Fee paid to the executor at execution time (signer-authorized).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce CCTP nonce used for the deposit.
     * @param cctpDeadline Deadline timestamp for the CCTP quote.
     */
    event CCTPDepositExecuted(
        uint256 amount,
        uint256 executionFee,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline
    );

    error InvalidExecutionFeeSignature();
    error ExecutionFeeSignatureExpired();
    error ExecutionFeeTooHigh();

    /// @notice EIP-712 typehash for executionFee signature verification.
    /// @dev Binds `paramsHash` so a signature issued for one leaf cannot be replayed against another;
    ///      binds `amount` so the signer prices the fee against the specific deposit size.
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 paramsHash,uint256 amount,uint256 executionFee,uint256 executionFeeDeadline)");

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /// @notice Signer that authorizes the runtime executionFee
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
     *      `submitterData` as `CCTPSubmitterData` (carries the periphery quote signature plus the local
     *      executionFee signature). ERC-20 only.
     *      Reverts: `ExecutionFeeSignatureExpired`, `InvalidExecutionFeeSignature`, `ExecutionFeeTooHigh`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        if (block.timestamp > sd.executionFeeDeadline) revert ExecutionFeeSignatureExpired();
        if (sd.executionFee > (sd.amount * dp.maxExecutionFeeBps) / BPS_SCALAR) revert ExecutionFeeTooHigh();
        _verifyExecutionFeeSignature(keccak256(params), sd);

        address inputToken = address(uint160(uint256(dp.burnToken)));

        if (sd.executionFee > 0) IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(dp, sd, depositAmount);

        emit CCTPDepositExecuted(sd.amount, sd.executionFee, sd.executionFeeRecipient, sd.nonce, sd.cctpDeadline);
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
            sd.signature
        );
    }

    function _verifyExecutionFeeSignature(bytes32 paramsHash, CCTPSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_CCTP_TYPEHASH, paramsHash, sd.amount, sd.executionFee, sd.executionFeeDeadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.executionFeeSignature) != signer) {
            revert InvalidExecutionFeeSignature();
        }
    }
}
