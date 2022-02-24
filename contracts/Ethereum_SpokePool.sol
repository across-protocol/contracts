//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice Ethereum L1 specific SpokePool.
 * @dev Used on Ethereum L1 to facilitate L2->L1 transfers.
 */

contract Ethereum_SpokePool is SpokePoolInterface, SpokePool, Ownable {
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyOwner nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyOwner nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public override onlyOwner nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer) public override onlyOwner nonReentrant {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot) public override onlyOwner nonReentrant {
        _relayRootBundle(relayerRefundRoot, slowRelayRoot);
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        IERC20(relayerRefundLeaf.l2TokenAddress).transfer(hubPool, relayerRefundLeaf.amountToReturn);
    }
}
