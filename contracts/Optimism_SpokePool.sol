//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import "@eth-optimism/contracts/L2/messaging/IL2ERC20Bridge.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice OVM specific SpokePool.
 * @dev Uses OVM cross-domain-enabled logic for access control.
 */

contract Optimism_SpokePool is CrossDomainEnabled, SpokePoolInterface, SpokePool {
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, _depositQuoteTimeBuffer, timerAddress)
    {}

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
    function setCrossDomainAdmin(address newCrossDomainAdmin)
        public
        override
        onlyFromCrossDomainAccount(crossDomainAdmin)
        nonReentrant
    {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyFromCrossDomainAccount(crossDomainAdmin) nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public override onlyFromCrossDomainAccount(crossDomainAdmin) nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint64 buffer)
        public
        override
        onlyFromCrossDomainAccount(crossDomainAdmin)
        nonReentrant
    {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof)
        public
        override
        onlyFromCrossDomainAccount(crossDomainAdmin)
        nonReentrant
    {
        _initializeRelayerRefund(relayerRepaymentDistributionProof);
    }

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        MerkleLib.DestinationDistribution memory distributionLeaf,
        bytes32[] memory inclusionProof
    ) public override nonReentrant {
        _distributeRelayerRefund(relayerRefundId, distributionLeaf, inclusionProof);

        // If `distributionLeaf.amountToReturn` is negative, then send L2 --> L1 message to bridge tokens back.
        // Note: This might not be an issue at all, but should this call go before or after the above internal method
        // that sends tokens from this contract to relayers on the same network?
        if (distributionLeaf.amountToReturn < 0) {
            // Do we need to perform any check about the last time that funds were bridged from L2 to L1?
            IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo(
                distributionLeaf.l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                // Note: Should we first multiply the int256 by -1 before casting to uint256 to be safer?
                uint256(distributionLeaf.amountToReturn), // _amount. Send the full balance of the deposit box to bridge.
                6_000_000, // _l1Gas. Unused, but included for potential forward compatibility considerations
                "" // _data. We don't need to send any data for the bridging action.
            );
        }

        emit TokensBridged(
            distributionLeaf.l2TokenAddress,
            hubPool,
            uint256(distributionLeaf.amountToReturn),
            6_000_000,
            msg.sender
        );
    }
}
