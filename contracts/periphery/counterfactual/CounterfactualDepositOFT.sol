// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

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

struct OFTRoute {
    OFTDepositParams depositParams;
    uint256 executionFee;
}

abstract contract CounterfactualDepositOFTModule is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    event OFTDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 oftDeadline);

    address public immutable oftSrcPeriphery;
    uint32 public immutable srcEid;

    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    function _oftRouteHash(OFTRoute memory route) internal pure returns (bytes32) {
        return keccak256(abi.encode(route));
    }

    function _executeOFTRoute(
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) internal {
        if (route.executionFee > 0) {
            IERC20(route.depositParams.token).safeTransfer(executionFeeRecipient, route.executionFee);
        }

        uint256 depositAmount = amount - route.executionFee;
        IERC20(route.depositParams.token).forceApprove(oftSrcPeriphery, depositAmount);

        SponsoredOFTInterface.Quote memory quote = SponsoredOFTInterface.Quote({
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

        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(quote, signature);
        emit OFTDepositExecuted(amount, executionFeeRecipient, nonce, oftDeadline);
    }
}
