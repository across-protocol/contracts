// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Permit2OrderLib.sol";
import "../external/interfaces/IPermit2.sol";
import "../interfaces/V3SpokePoolInterface.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Permit2Depositor processes an external order type and translates it into an AcrossV2 deposit.
 */
contract Permit2Depositor {
    using SafeERC20 for IERC20;

    // SpokePool that this contract can deposit to.
    V3SpokePoolInterface public immutable spokePool;

    // Permit2 contract
    IPermit2 public immutable permit2;

    // quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
    // This is a somewhat arbitrary conversion, but order creators need some way to precompute the quote timestamp.
    uint256 public immutable quoteBeforeDeadline;

    /**
     * @notice Construct the Permit2Depositor.
     * @param _spokePool SpokePool that this contract can deposit to.
     * @param _permit2 Permit2 contract
     * @param _quoteBeforeDeadline quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
     */
    constructor(
        V3SpokePoolInterface _spokePool,
        IPermit2 _permit2,
        uint256 _quoteBeforeDeadline
    ) {
        spokePool = _spokePool;
        permit2 = _permit2;
        quoteBeforeDeadline = _quoteBeforeDeadline;
    }

    /**
     * @notice Uses a permit2 order to deposit to a SpokePool.
     * @param signedOrder Signed external order type that is processed to produce the deposit. See Permit2OrderLib for details
     */
    function permit2Deposit(SignedOrder calldata signedOrder) external {
        CrossChainLimitOrder memory order = Permit2OrderLib._processPermit2Order(permit2, signedOrder);
        uint32 fillDeadline = SafeCast.toUint32(block.timestamp + order.info.fillPeriod);

        // User input amount and filler collateral are added together to get the deposit amount.
        // If the user gets filled correctly, the filler gets their collateral back.
        // If the user is not filled or filled by someone else, the filler loses their collateral.
        uint256 amountToDeposit = order.input.amount + order.fillerCollateral.amount;

        IERC20(order.input.token).safeIncreaseAllowance(address(spokePool), amountToDeposit);
        spokePool.depositV3(
            order.info.offerer,
            // Note: Permit2OrderLib checks that order only has a single output.
            order.outputs[0].recipient,
            order.input.token,
            order.outputs[0].token,
            amountToDeposit,
            order.outputs[0].amount,
            order.outputs[0].chainId,
            // Sender is assumed to be the same address that will fill on other chains.
            msg.sender,
            SafeCast.toUint32(order.info.initiateDeadline - quoteBeforeDeadline),
            fillDeadline,
            // The entire fill period is exclusive.
            fillDeadline,
            ""
        );
    }
}
