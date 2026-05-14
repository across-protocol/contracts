// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";
import { ChainConfig } from "./ChainConfig.sol";
import { OFT_SRC_PERIPHERY_ID } from "./ChainConfigIds.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `tokenId` is a chain-agnostic id (see ChainConfigIds.sol) resolved against the registry
 *      at execute time. `maxExecutionFeeBps` caps the execution fee the submitter may claim,
 *      expressed in basis points of `amount`.
 */
struct OFTDepositParams {
    uint32 dstEid;
    bytes32 destinationHandler;
    uint32 tokenId;
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
 * @dev `signature` is verified locally against the registry-configured signer and covers
 *      `(amount, executionFee, nonce, oftDeadline, signatureDeadline)`. `peripherySignature` is
 *      forwarded unchanged to the SponsoredOFTSrcPeriphery and validated there against the
 *      periphery's own schema.
 */
struct OFTSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    uint32 signatureDeadline;
    bytes signature;
    bytes peripherySignature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT.
 * @dev Chain-agnostic: same bytecode + same constructor arg (registry) → same deterministic address
 *      on every EVM chain. The OFT src periphery, src endpoint id, and bridged token address are
 *      resolved from `ChainConfig` at execute time.
 *
 *      Called via delegatecall from the CounterfactualDeposit dispatcher. The local impl signature
 *      uses EIP-712 with `address(this)` (the clone) as the verifying contract, so signer
 *      authorizations cannot be replayed across clones.
 *      msg.value covers LayerZero native messaging fees.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFT is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after an OFT deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Execution fee paid to the submitter-designated recipient.
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

    error RegistryUnset(uint32 id);
    error ExecutionFeeTooHigh();
    error SignatureExpired();
    error InvalidSignature();

    /// @notice EIP-712 typehash for the local execution-fee envelope. `tokenId` binds the
    ///         signature to a specific source token so it cannot be replayed across leaves naming
    ///         different tokens.
    bytes32 public constant EXECUTE_OFT_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteOFTDeposit(uint32 tokenId,uint256 amount,uint256 executionFee,bytes32 nonce,uint256 oftDeadline,uint32 signatureDeadline)"
        );

    /// @notice Chain-local config registry. Same address on every chain.
    ChainConfig public immutable registry;

    constructor(address _registry) EIP712("CounterfactualDepositOFT", "v1.0.0") {
        registry = ChainConfig(_registry);
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `params` is ABI-encoded as `OFTDepositParams`;
     *      `submitterData` as `OFTSubmitterData`. The impl verifies `signature` locally against
     *      the registry signer; `peripherySignature` is forwarded to the OFT periphery.
     *      ERC-20 only. Forwards `msg.value` for LayerZero messaging fees.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        OFTDepositParams memory dp = abi.decode(params, (OFTDepositParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        if (sd.executionFee > (dp.maxExecutionFeeBps * sd.amount) / BPS_SCALAR) revert ExecutionFeeTooHigh();
        _verifySignature(dp.tokenId, sd);

        address token = _requireRegistryAddress(registry.tokens(dp.tokenId), dp.tokenId);
        address oftSrcPeriphery = _requireRegistryAddress(registry.bridges(OFT_SRC_PERIPHERY_ID), OFT_SRC_PERIPHERY_ID);
        uint32 srcEid = registry.oftSrcEid();

        if (sd.executionFee > 0) IERC20(token).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(dp, sd, depositAmount, oftSrcPeriphery, srcEid);

        emit OFTDepositExecuted(sd.amount, sd.executionFee, sd.executionFeeRecipient, sd.nonce, sd.oftDeadline);
    }

    /**
     * @notice Calls deposit on the SponsoredOFTSrcPeriphery with the constructed quote.
     */
    function _deposit(
        OFTDepositParams memory dp,
        OFTSubmitterData memory sd,
        uint256 depositAmount,
        address oftSrcPeriphery,
        uint32 srcEid
    ) private {
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
            sd.peripherySignature
        );
    }

    function _verifySignature(uint32 tokenId, OFTSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_OFT_DEPOSIT_TYPEHASH,
                tokenId,
                sd.amount,
                sd.executionFee,
                sd.nonce,
                sd.oftDeadline,
                sd.signatureDeadline
            )
        );
        address signer = registry.signer();
        if (signer == address(0)) revert InvalidSignature();
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.signature) != signer) revert InvalidSignature();
    }

    function _requireRegistryAddress(address resolved, uint32 id) private pure returns (address) {
        if (resolved == address(0)) revert RegistryUnset(id);
        return resolved;
    }
}
