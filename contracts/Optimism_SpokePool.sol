//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

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
    // "l1Gas" parameter used in call to bridge tokens from this contract back to L1 via `IL2ERC20Bridge`.
    uint32 public l1Gas = 5_000_000;

    address public l1EthWrapper;

    address public l2Eth;

    event OptimismTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged, uint256 l1Gas);
    event SetL1Gas(uint32 indexed newL1Gas);

    constructor(
        address _l1EthWrapper,
        address _l2Eth,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress)
    {}

    /**************************************
     *    CROSS-CHAIN ADMIN FUNCTIONS     *
     **************************************/

    function setL1GasLimit(uint32 newl1Gas) public onlyFromCrossDomainAccount(crossDomainAdmin) {
        _setL1GasLimit(newl1Gas);
    }

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

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _setL1GasLimit(uint32 _l1Gas) internal {
        l1Gas = _l1Gas;
        emit SetL1Gas(l1Gas);
    }

    function _bridgeTokensToHubPool(DestinationDistributionLeaf memory distributionLeaf) internal override {
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (distributionLeaf.l2TokenAddress == address(weth)) {
            WETH9(distributionLeaf.l2TokenAddress).withdraw(distributionLeaf.amountToReturn); // Unwrap ETH.
            distributionLeaf.l2TokenAddress = l2Eth; // Set the l2TokenAddress to ETH.
        }
        IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo(
            distributionLeaf.l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
            hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
            distributionLeaf.amountToReturn, // _amount.
            l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
            "" // _data. We don't need to send any data for the bridging action.
        );

        emit OptimismTokensBridged(distributionLeaf.l2TokenAddress, hubPool, distributionLeaf.amountToReturn, l1Gas);
    }
}
