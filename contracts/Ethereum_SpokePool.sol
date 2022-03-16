// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice Ethereum L1 specific SpokePool. Used on Ethereum L1 to facilitate L2->L1 transfers.
 */
contract Ethereum_SpokePool is SpokePool, Ownable {
    /**
     * @notice Construct the Ethereum SpokePool.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     * @param timerAddress Timer address to set.
     */
    constructor(
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(msg.sender, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        IERC20(relayerRefundLeaf.l2TokenAddress).transfer(hubPool, relayerRefundLeaf.amountToReturn);
    }

    // Admin is simply owner which should be same account that owns the HubPool deployed on this network. A core
    // assumption of this contract system is that the HubPool is deployed on Ethereum.
    // @dev: This is an internal method that we purposefully add a reentrancy guard to. We don't add the `nonReentrant`
    // modifier to `onlyAdmin` functions in the base `SpokePool` contract because the `Polygon_SpokePool` will
    // call these methods internally via the `processMessageFromRoot`. The other spoke pools like `Optimism_SpokePool`
    // and `Arbitrum_SpokePool` have their admin functions triggered by an external contract so we should be
    // reentrancy guarding those methods. However, in the `Polygon_SpokePool` case we need to reentrancy guard at the
    // `processMessageFromRoot` method instead of at the admin functions.
    function _requireAdminSender() internal override onlyOwner nonReentrant {}
}
