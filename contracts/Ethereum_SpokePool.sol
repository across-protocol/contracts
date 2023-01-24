// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Ethereum L1 specific SpokePool. Used on Ethereum L1 to facilitate L2->L1 transfers.
 */
contract Ethereum_SpokePool is SpokePool, Ownable {
    using SafeERC20 for IERC20;

    /**
     * @notice Construct the Ethereum SpokePool.
     * @dev crossDomainAdmin is unused on this contract.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     * @param timerAddress Timer address to set.
     */
    constructor(
        uint32 _initialDepositId,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_initialDepositId, _hubPool, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        IERC20(relayerRefundLeaf.l2TokenAddress).safeTransfer(hubPool, relayerRefundLeaf.amountToReturn);
    }

    // The SpokePool deployed to the same network as the HubPool must be owned by the HubPool.
    // A core assumption of this contract system is that the HubPool is deployed on Ethereum.
    function _requireAdminSender() internal override onlyOwner {}
}
