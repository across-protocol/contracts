// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

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
}

struct CCTPRoute {
    CCTPDepositParams depositParams;
    uint256 executionFee;
}

abstract contract CounterfactualDepositCCTPModule is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    event CCTPDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 cctpDeadline);

    address public immutable srcPeriphery;
    uint32 public immutable sourceDomain;

    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    function _cctpRouteHash(CCTPRoute memory route) internal pure returns (bytes32) {
        return keccak256(abi.encode(route));
    }

    function _executeCCTPRoute(
        CCTPRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) internal {
        address inputToken = address(uint160(uint256(route.depositParams.burnToken)));
        if (route.executionFee > 0) IERC20(inputToken).safeTransfer(executionFeeRecipient, route.executionFee);

        uint256 depositAmount = amount - route.executionFee;
        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: route.depositParams.destinationDomain,
                mintRecipient: route.depositParams.mintRecipient,
                amount: depositAmount,
                burnToken: route.depositParams.burnToken,
                destinationCaller: route.depositParams.destinationCaller,
                maxFee: (depositAmount * route.depositParams.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: route.depositParams.minFinalityThreshold,
                nonce: nonce,
                deadline: cctpDeadline,
                maxBpsToSponsor: route.depositParams.maxBpsToSponsor,
                maxUserSlippageBps: route.depositParams.maxUserSlippageBps,
                finalRecipient: route.depositParams.finalRecipient,
                finalToken: route.depositParams.finalToken,
                destinationDex: route.depositParams.destinationDex,
                accountCreationMode: route.depositParams.accountCreationMode,
                executionMode: route.depositParams.executionMode,
                actionData: route.depositParams.actionData
            }),
            signature
        );

        emit CCTPDepositExecuted(amount, executionFeeRecipient, nonce, cctpDeadline);
    }
}
