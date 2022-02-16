//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

interface StandardBridgeLike {
    function outboundTransfer(
        address _l1Token,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external payable returns (bytes memory);
}

/**
 * @notice AVM specific SpokePool.
 * @dev Uses AVM cross-domain-enabled logic for access control.
 */

contract Arbitrum_SpokePool is SpokePoolInterface, SpokePool, Ownable {
    // Address of the Arbitrum L2 token gateway.
    address public l2GatewayRouter;

    event ArbitrumTokensBridged(address indexed l1Token, address target, uint256 numberOfTokensBridged);
    event SetL2GatewayRouter(address indexed newL2GatewayRouter);

    constructor(
        address _l2GatewayRouter,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {
        _setL2GatewayRouter(_l2GatewayRouter);
    }

    modifier onlyFromCrossDomainAccount(address l1Counterpart) {
        require(msg.sender == _applyL1ToL2Alias(l1Counterpart), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/
    function setL2GatewayRouter(address newL2GatewayRouter) public onlyOwner nonReentrant {
        _setL2GatewayRouter(newL2GatewayRouter);
    }

    /**************************************
     *    CROSS-CHAIN ADMIN FUNCTIONS     *
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
        uint32 destinationChainId,
        bool enable
    ) public override onlyFromCrossDomainAccount(crossDomainAdmin) nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer)
        public
        override
        onlyFromCrossDomainAccount(crossDomainAdmin)
        nonReentrant
    {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionRoot, bytes32 slowRelayRoot)
        public
        override
        onlyFromCrossDomainAccount(crossDomainAdmin)
        nonReentrant
    {
        _initializeRelayerRefund(relayerRepaymentDistributionRoot, slowRelayRoot);
    }

    function _bridgeTokensToHubPool(DestinationDistributionLeaf memory distributionLeaf) internal override {
        StandardBridgeLike(l2GatewayRouter).outboundTransfer(
            // THIS IS A PROBLEM!!, we need the L1 token address not the L2 token address
            address(0), // _l1Token. Address of the L1 token to bridge over.
            hubPool, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
            distributionLeaf.amountToReturn, // _amount.
            "" // _data. We don't need to send any data for the bridging action.
        );
        emit ArbitrumTokensBridged(address(0), hubPool, distributionLeaf.amountToReturn);
    }

    function _setL2GatewayRouter(address _l2GatewayRouter) internal {
        l2GatewayRouter = _l2GatewayRouter;
        emit SetL2GatewayRouter(l2GatewayRouter);
    }

    // l1 addresses are transformed during l1->l2 calls. See https://developer.offchainlabs.com/docs/l1_l2_messages#address-aliasing for more information.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
    }
}
