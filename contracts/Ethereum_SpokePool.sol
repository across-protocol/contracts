// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @notice Ethereum L1 specific SpokePool. Used on Ethereum L1 to facilitate L2->L1 transfers.
 */
contract Ethereum_SpokePool is SpokePool, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice Construct the Ethereum SpokePool.
     * @dev crossDomainAdmin is unused on this contract.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(uint32 _initialDepositId, address _hubPool) public initializer {
        __Ownable_init();
        __SpokePool_init(_initialDepositId, _hubPool, _hubPool);
    }

    function wrappedNativeToken() public pure override returns (WETH9Interface) {
        return WETH9Interface(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        IERC20Upgradeable(relayerRefundLeaf.l2TokenAddress).safeTransfer(hubPool, relayerRefundLeaf.amountToReturn);
    }

    // The SpokePool deployed to the same network as the HubPool must be owned by the HubPool.
    // A core assumption of this contract system is that the HubPool is deployed on Ethereum.
    function _requireAdminSender() internal override onlyOwner {}
}
