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
        address _l1EthWrapper,
        address _l2Eth,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    /**
     * @notice Changes the L1 contract that can trigger admin functions on this contract.
     * @dev This should be set to the address of the L1 contract that ultimately relays a cross-domain message, which
     * is expected to be the Optimism_Adapter.
     * @dev Only callable by the existing admin via the Optimism cross domain messenger.
     * @param newCrossDomainAdmin address of the new L1 admin contract.
     */
    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyOwner nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyOwner nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint32 destinationChainId,
        bool enable
    ) public override onlyOwner nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer) public override onlyOwner nonReentrant {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionRoot, bytes32 slowRelayRoot)
        public
        override
        onlyOwner
        nonReentrant
    {
        _initializeRelayerRefund(relayerRepaymentDistributionRoot, slowRelayRoot);
    }

    function _bridgeTokensToHubPool(DestinationDistributionLeaf memory distributionLeaf) internal override {
        IERC20(distributionLeaf.l2TokenAddress).transfer(hubPool, distributionLeaf.amountToReturn);
    }
}
