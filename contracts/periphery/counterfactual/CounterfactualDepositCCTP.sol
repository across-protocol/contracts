// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 *      at execute time. The same id means the same canonical token on every chain.
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
    uint256 executionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct CCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Chain-agnostic: same bytecode + same constructor arg (registry) → same deterministic address
 *      on every EVM chain. All chain-specific values (CCTP source domain, src periphery address,
 *      burn token address) are resolved from `ChainConfig` at execute time.
 *
 *      Called via delegatecall from the CounterfactualDeposit dispatcher.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce CCTP nonce used for the deposit.
     * @param cctpDeadline Deadline timestamp for the CCTP quote.
     */
    event CCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline
    );

    /// @notice Reverts when a registry id resolves to `address(0)`.
    error RegistryUnset(uint32 id);

    /// @notice Chain-local config registry. Same address on every chain.
    ChainConfig public immutable registry;

    constructor(address _registry) {
        registry = ChainConfig(_registry);
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `params` is ABI-encoded as `CCTPDepositParams`;
     *      `submitterData` as `CCTPSubmitterData` (includes a signature forwarded to the CCTP periphery).
     *      ERC-20 only (no native tokens). No local signature verification — delegated to `srcPeriphery`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        address burnToken = _requireRegistryAddress(registry.tokens(dp.burnTokenId), dp.burnTokenId);
        address srcPeriphery = _requireRegistryAddress(registry.bridges(CCTP_SRC_PERIPHERY_ID), CCTP_SRC_PERIPHERY_ID);
        uint32 sourceDomain = registry.cctpSourceDomain();

        if (dp.executionFee > 0) IERC20(burnToken).safeTransfer(sd.executionFeeRecipient, dp.executionFee);

        uint256 depositAmount = sd.amount - dp.executionFee;

        IERC20(burnToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(dp, sd, depositAmount, srcPeriphery, sourceDomain, burnToken);

        emit CCTPDepositExecuted(sd.amount, sd.executionFeeRecipient, sd.nonce, sd.cctpDeadline);
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
            sd.signature
        );
    }

    function _requireRegistryAddress(address resolved, uint32 id) private pure returns (address) {
        if (resolved == address(0)) revert RegistryUnset(id);
        return resolved;
    }
}
