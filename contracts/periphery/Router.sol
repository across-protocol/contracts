// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

struct SubmitterRequirement {
    // Address OR Auction
    uint8 typ;
    bytes data;
}

struct MinTokenRequirement {
    address token;
    uint256 minAmount;
}

struct Call {
    address target;
    bytes cdata;
}

// Amount is determined at execution time from Executor balance
struct BridgeParams {
    uint256 srcChainId;
    uint256 dstChainId;
    address bridge; // The bridge periphery address
    bytes otherParams; // Bridge-specific: recipient, fees, etc.
}

interface IBridgePeriphery {
    function deposit(address token, uint256 amount, uint256 dstChainId, bytes calldata params) external;
}

struct UserOrder {
    address tokenIn;
    uint256 amountIn;
    SubmitterRequirement submitterReq;
    // Token requirement checked before bridge call
    MinTokenRequirement tokenReq;
    // Bridge params (amount determined at execution)
    BridgeParams bridgeParams;
    uint256 salt;
}

struct GaslessAuthData {
    uint8 authType;
    bytes data;
}

struct SubmitterData {
    GaslessAuthData gaslessAuthData;
    bytes submitterAuthData;
    Call[] actions;
}

contract OrderGateway {
    function submit(
        UserOrder calldata order,
        SubmitterData calldata submitterData
    ) external /* onlyValidSubmitter(...) */ {
        // 1. Pull user funds (via permit, transfer, etc.)
        // 2. Forward to OrderExecutor
    }
}

contract OrderExecutor {
    using SafeERC20 for IERC20;

    error TokenRequirementNotMet(address token, uint256 required, uint256 actual);
    error ActionFailed(uint256 index);

    function execute(
        address token,
        uint256 amount,
        MinTokenRequirement calldata tokenReq,
        Call[] calldata submitterActions,
        BridgeParams calldata bridgeParams
    ) external {
        // 0. Pull tokens from AllowanceHolder
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // 1. Execute submitter actions (DEX swaps, etc.)
        uint256 len = submitterActions.length;
        for (uint256 i = 0; i < len; ++i) {
            (bool success, ) = submitterActions[i].target.call(submitterActions[i].cdata);
            if (!success) revert ActionFailed(i);
        }

        // 2. Check token requirement
        uint256 balance = IERC20(tokenReq.token).balanceOf(address(this));
        if (balance < tokenReq.minAmount) {
            revert TokenRequirementNotMet(tokenReq.token, tokenReq.minAmount, balance);
        }

        // 3. Bridge with actual balance (typed call - no offset calculation)
        IERC20(tokenReq.token).forceApprove(bridgeParams.bridge, balance);
        IBridgePeriphery(bridgeParams.bridge).deposit(
            tokenReq.token,
            balance,
            bridgeParams.dstChainId,
            bridgeParams.otherParams
        );
    }
}
