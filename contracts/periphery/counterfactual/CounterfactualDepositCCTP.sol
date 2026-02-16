// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters for CCTP deposits
 */
struct CCTPImmutables {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint256 executionFee;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes32 userWithdrawAddress;
    bytes32 adminWithdrawAddress;
    bytes actionData;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP, deployed as EIP-1167 clones
 * @dev The factory deploys minimal proxies (clones) of this contract using OZ Clones.cloneDeterministicWithImmutableArgs.
 *      Route parameters are appended to the clone bytecode and read via Clones.fetchCloneArgs.
 *      On execution, the clone builds a SponsoredCCTPQuote from its immutable route params + caller-supplied
 *      execution params (amount, nonce, cctpDeadline, executeDepositDeadline) and forwards it to SponsoredCCTPSrcPeriphery.
 */
contract CounterfactualDepositCCTP is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /**
     * @notice Executes a deposit via SponsoredCCTP
     * @param params Route parameters (verified against stored hash)
     * @param amount Gross amount of burnToken (includes executionFee)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param nonce Unique nonce for SponsoredCCTP replay protection
     * @param cctpDeadline Deadline for the SponsoredCCTP quote (validated by SrcPeriphery)
     * @param signature Signature from SponsoredCCTP quote signer
     */
    function executeDeposit(
        CCTPImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) external {
        _verifyParams(params);

        address burnTokenAddr = address(uint160(uint256(params.burnToken)));
        if (IERC20(burnTokenAddr).balanceOf(address(this)) < amount) revert InsufficientBalance();

        uint256 depositAmount = amount - params.executionFee;
        if (params.executionFee > 0) {
            IERC20(burnTokenAddr).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        IERC20(burnTokenAddr).forceApprove(srcPeriphery, depositAmount);
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: params.destinationDomain,
                mintRecipient: params.mintRecipient,
                amount: depositAmount,
                burnToken: params.burnToken,
                destinationCaller: params.destinationCaller,
                maxFee: (depositAmount * params.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: params.minFinalityThreshold,
                nonce: nonce,
                deadline: cctpDeadline,
                maxBpsToSponsor: params.maxBpsToSponsor,
                maxUserSlippageBps: params.maxUserSlippageBps,
                finalRecipient: params.finalRecipient,
                finalToken: params.finalToken,
                destinationDex: params.destinationDex,
                accountCreationMode: params.accountCreationMode,
                executionMode: params.executionMode,
                actionData: params.actionData
            }),
            signature
        );

        emit DepositExecuted(address(this), depositAmount, nonce);
    }

    function adminWithdraw(CCTPImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _adminWithdraw(params.adminWithdrawAddress, token, to, amount);
    }

    function userWithdraw(CCTPImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _userWithdraw(params.userWithdrawAddress, token, to, amount);
    }

    function _verifyParams(CCTPImmutables memory params) internal view {
        _verifyParamsHash(keccak256(abi.encode(params)));
    }
}
