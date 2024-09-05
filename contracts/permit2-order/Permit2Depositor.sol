// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Permit2OrderLib.sol";
import "../external/interfaces/IPermit2.sol";
import "../interfaces/V3SpokePoolInterface.sol";

import "@openzeppelin/contracts5/utils/math/SafeCast.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";

/**
 * @notice Permit2Depositor processes an external order type and translates it into an AcrossV3 deposit.
 */
contract Permit2Depositor {
    using SafeERC20 for IERC20;

    // SpokePool that this contract can deposit to.
    V3SpokePoolInterface public immutable SPOKE_POOL;

    // Permit2 contract
    IPermit2 public immutable PERMIT2;

    // quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
    // This is a somewhat arbitrary conversion, but order creators need some way to precompute the quote timestamp.
    uint256 public immutable QUOTE_BEFORE_DEADLINE;

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
        SPOKE_POOL = _spokePool;
        PERMIT2 = _permit2;
        QUOTE_BEFORE_DEADLINE = _quoteBeforeDeadline;
    }

    /**
     * @notice Uses a permit2 order to deposit to a SpokePool.
     * @param signedOrder Signed external order type that is processed to produce the deposit. See Permit2OrderLib for details
     * @param destinationChainFillerAddress Address of the filler on the destination chain. Specified by caller
     * to avoid issue if destination and current network have different address derivation schemes.
     */
    function permit2Deposit(SignedOrder calldata signedOrder, address destinationChainFillerAddress) external {
        CrossChainLimitOrder memory order = Permit2OrderLib._processPermit2Order(PERMIT2, signedOrder);
        uint32 fillDeadline = SafeCast.toUint32(block.timestamp + order.info.fillPeriod);

        // User input amount and filler collateral are added together to get the deposit amount.
        // If the user gets filled correctly, the filler gets their collateral back.
        // If the user is not filled or filled by someone else, the filler loses their collateral.
        uint256 amountToDeposit = order.input.amount + order.fillerCollateral.amount;

        IERC20(order.input.token).forceApprove(address(SPOKE_POOL), amountToDeposit);
        SPOKE_POOL.depositV3(
            order.info.offerer,
            // Note: Permit2OrderLib checks that order only has a single output.
            order.outputs[0].recipient,
            order.input.token,
            order.outputs[0].token,
            amountToDeposit,
            order.outputs[0].amount,
            order.outputs[0].chainId,
            destinationChainFillerAddress,
            SafeCast.toUint32(order.info.initiateDeadline - QUOTE_BEFORE_DEADLINE),
            fillDeadline,
            // The entire fill period is exclusive.
            fillDeadline,
            ""
        );
    }
}
