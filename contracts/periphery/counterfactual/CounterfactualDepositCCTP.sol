// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";
import { ChainConfig } from "./ChainConfig.sol";
import { CCTP_SRC_PERIPHERY_ID } from "./ChainConfigIds.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `burnTokenId` is a chain-agnostic id (see ChainConfigIds.sol) resolved against the registry
 *      at execute time. `maxExecutionFeeBps` caps the execution fee the submitter may claim,
 *      expressed in basis points of `amount`.
 */
struct CCTPDepositParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    uint32 burnTokenId;
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
 * @dev `signature` is verified locally against the registry-configured signer and covers
 *      `(amount, executionFee, nonce, cctpDeadline, signatureDeadline)`. `peripherySignature` is
 *      forwarded unchanged to the SponsoredCCTPSrcPeriphery and validated there against the
 *      periphery's own schema.
 */
struct CCTPSubmitterData {
    uint256 amount;
    uint256 executionFee;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    uint32 signatureDeadline;
    bytes signature;
    bytes peripherySignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Chain-agnostic: same bytecode + same constructor arg (registry) → same deterministic address
 *      on every EVM chain. All chain-specific values (CCTP source domain, src periphery address,
 *      burn token address) are resolved from `ChainConfig` at execute time.
 *
 *      Called via delegatecall from the CounterfactualDeposit dispatcher. The local impl signature
 *      uses EIP-712 with `address(this)` (the clone) as the verifying contract, so signer
 *      authorizations cannot be replayed across clones.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFee Execution fee paid to the submitter-designated recipient.
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

    error RegistryUnset(uint32 id);
    error ExecutionFeeTooHigh();
    error SignatureExpired();
    error InvalidSignature();

    /// @notice EIP-712 typehash for the local execution-fee envelope. `burnTokenId` binds the
    ///         signature to a specific source token so it cannot be replayed across leaves naming
    ///         different burn tokens.
    bytes32 public constant EXECUTE_CCTP_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteCCTPDeposit(uint32 burnTokenId,uint256 amount,uint256 executionFee,bytes32 nonce,uint256 cctpDeadline,uint32 signatureDeadline)"
        );

    /// @notice Chain-local config registry. Same address on every chain.
    ChainConfig public immutable registry;

    constructor(address _registry) EIP712("CounterfactualDepositCCTP", "v1.0.0") {
        registry = ChainConfig(_registry);
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `params` is ABI-encoded as `CCTPDepositParams`;
     *      `submitterData` as `CCTPSubmitterData`. The impl verifies `signature` locally against
     *      the registry signer; `peripherySignature` is forwarded to the CCTP periphery.
     *      ERC-20 only (no native tokens).
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        if (sd.executionFee > (dp.maxExecutionFeeBps * sd.amount) / BPS_SCALAR) revert ExecutionFeeTooHigh();
        _verifySignature(dp.burnTokenId, sd);

        address burnToken = _requireRegistryAddress(registry.tokens(dp.burnTokenId), dp.burnTokenId);
        address srcPeriphery = _requireRegistryAddress(registry.bridges(CCTP_SRC_PERIPHERY_ID), CCTP_SRC_PERIPHERY_ID);
        uint32 sourceDomain = registry.cctpSourceDomain();

        if (sd.executionFee > 0) IERC20(burnToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(burnToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(dp, sd, depositAmount, srcPeriphery, sourceDomain, burnToken);

        emit CCTPDepositExecuted(sd.amount, sd.executionFee, sd.executionFeeRecipient, sd.nonce, sd.cctpDeadline);
    }

    /**
     * @notice Calls depositForBurn on the SponsoredCCTPSrcPeriphery with the constructed quote.
     */
    function _depositForBurn(
        CCTPDepositParams memory dp,
        CCTPSubmitterData memory sd,
        uint256 depositAmount,
        address srcPeriphery,
        uint32 sourceDomain,
        address burnToken
    ) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: dp.destinationDomain,
                mintRecipient: dp.mintRecipient,
                amount: depositAmount,
                burnToken: bytes32(uint256(uint160(burnToken))),
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
            sd.peripherySignature
        );
    }

    function _verifySignature(uint32 burnTokenId, CCTPSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_CCTP_DEPOSIT_TYPEHASH,
                burnTokenId,
                sd.amount,
                sd.executionFee,
                sd.nonce,
                sd.cctpDeadline,
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
