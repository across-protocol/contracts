// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { ERC7683OrderDepositor } from "./ERC7683OrderDepositor.sol";
import "../SpokePool.sol";
import "../external/interfaces/IPermit2.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

/**
 * @notice ERC7683OrderDepositorExternal processes an external order type and translates it into an AcrossV3Deposit
 * that it sends to the SpokePool contract.
 * @custom:security-contact bugs@across.to
 */
contract ERC7683OrderDepositorExternal is ERC7683OrderDepositor, Ownable, MultiCaller {
    using SafeERC20 for IERC20;

    event SetDestinationSettler(
        uint256 indexed chainId,
        address indexed prevDestinationSettler,
        address indexed destinationSettler
    );

    SpokePool public immutable SPOKE_POOL;

    // Mapping of chainIds to destination settler addresses.
    mapping(uint256 => address) public destinationSettlers;

    constructor(
        SpokePool _spokePool,
        IPermit2 _permit2,
        uint256 _quoteBeforeDeadline
    ) ERC7683OrderDepositor(_permit2, _quoteBeforeDeadline) {
        SPOKE_POOL = _spokePool;
    }

    function setDestinationSettler(uint256 chainId, address destinationSettler) external {
        address prevDestinationSettler = destinationSettlers[chainId];
        destinationSettlers[chainId] = destinationSettler;
        emit SetDestinationSettler(chainId, prevDestinationSettler, destinationSettler);
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
        uint256 depositNonce,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) internal override {
        IERC20(inputToken).safeIncreaseAllowance(address(SPOKE_POOL), inputAmount);

        if (depositNonce == 0) {
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
        } else {
            SPOKE_POOL.unsafeDepositV3(
                depositor,
                recipient,
                inputToken,
                outputToken,
                inputAmount,
                outputAmount,
                destinationChainId,
                exclusiveRelayer,
                depositNonce,
                quoteTimestamp,
                fillDeadline,
                exclusivityDeadline,
                message
            );
        }
    }

    function computeDepositId(uint256 depositNonce, address depositor) public view override returns (uint256) {
        return
            depositNonce == 0
                ? SPOKE_POOL.numberOfDeposits()
                : SPOKE_POOL.getUnsafeDepositId(address(this), depositor, depositNonce);
    }

    function _destinationSettler(uint256 chainId) internal view override returns (address) {
        return destinationSettlers[chainId];
    }
}
