// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC7683OrderDepositor } from "./ERC7683OrderDepositor.sol";
import "../interfaces/V3SpokePoolInterface.sol";
import "../external/interfaces/IPermit2.sol";

/**
 * @notice ERC7683OrderDepositorExternal processes an external order type and translates it into an AcrossV3Deposit
 * that it sends to the SpokePool contract.
 */
contract ERC7683OrderDepositorExternal is ERC7683OrderDepositor {
    using SafeERC20 for IERC20;
    V3SpokePoolInterface public immutable SPOKE_POOL;

    constructor(
        V3SpokePoolInterface _spokePool,
        IPermit2 _permit2,
        uint256 _quoteBeforeDeadline
    ) ERC7683OrderDepositor(_permit2, _quoteBeforeDeadline) {
        SPOKE_POOL = _spokePool;
    }

    function _callDeposit(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) internal override {
        IERC20(inputToken).safeIncreaseAllowance(address(SPOKE_POOL), inputAmount);

        SPOKE_POOL.depositV3(
            depositor,
            recipient,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            message
        );
    }
}
