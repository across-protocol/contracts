// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/// @notice Minimal source periphery interface used by this module.
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/// @notice OFT fields forwarded into SponsoredOFT quotes.
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

/// @notice OFT route leaf payload committed into the routes merkle tree.
struct OFTRoute {
    OFTDepositParams depositParams;
    uint256 executionFee;
}

/**
 * @title CounterfactualDepositOFTModule
 * @notice OFT execution module used by the unified counterfactual implementation.
 */
abstract contract CounterfactualDepositOFTModule is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    event OFTDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 oftDeadline);

    address public immutable oftSrcPeriphery;
    uint32 public immutable srcEid;

    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    /**
     * @dev Hashes OFT route params into a merkle leaf payload component.
     */
    function _oftRouteHash(OFTRoute memory route) internal pure returns (bytes32) {
        return keccak256(abi.encode(route));
    }

    /**
     * @dev Executes an OFT deposit route after outer merkle proof validation.
     */
    function _executeOFTRoute(
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) internal {
        _executeOFTRouteMemory(route, amount, executionFeeRecipient, nonce, oftDeadline, signature);
    }

    /**
     * @dev Executes an OFT deposit route using a memory signature payload.
     */
    function _executeOFTRouteMemory(
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes memory signature
    ) internal {
        if (route.executionFee > 0) {
            IERC20(route.depositParams.token).safeTransfer(executionFeeRecipient, route.executionFee);
        }

        uint256 depositAmount = amount - route.executionFee;
        IERC20(route.depositParams.token).forceApprove(oftSrcPeriphery, depositAmount);

        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            _buildOFTQuote(route, depositAmount, nonce, oftDeadline),
            signature
        );
        emit OFTDepositExecuted(amount, executionFeeRecipient, nonce, oftDeadline);
    }

    /**
     * @dev Builds the SponsoredOFT quote payload for `deposit`.
     */
    function _buildOFTQuote(
        OFTRoute memory route,
        uint256 depositAmount,
        bytes32 nonce,
        uint256 oftDeadline
    ) private view returns (SponsoredOFTInterface.Quote memory) {
        return
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: route.depositParams.dstEid,
                    destinationHandler: route.depositParams.destinationHandler,
                    amountLD: depositAmount,
                    nonce: nonce,
                    deadline: oftDeadline,
                    maxBpsToSponsor: route.depositParams.maxBpsToSponsor,
                    maxUserSlippageBps: route.depositParams.maxUserSlippageBps,
                    finalRecipient: route.depositParams.finalRecipient,
                    finalToken: route.depositParams.finalToken,
                    destinationDex: route.depositParams.destinationDex,
                    lzReceiveGasLimit: route.depositParams.lzReceiveGasLimit,
                    lzComposeGasLimit: route.depositParams.lzComposeGasLimit,
                    maxOftFeeBps: route.depositParams.maxOftFeeBps,
                    accountCreationMode: route.depositParams.accountCreationMode,
                    executionMode: route.depositParams.executionMode,
                    actionData: route.depositParams.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({
                    refundRecipient: route.depositParams.refundRecipient
                })
            });
    }
}
