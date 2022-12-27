// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";

/**
 * @notice AVM specific SpokePool. Uses AVM cross-domain-enabled logic to implement admin only access to functions.
 */
contract Arbitrum_SpokePool is SpokePool {
    // Admin controlled mapping of arbitrum tokens to L1 counterpart. L1 counterpart addresses
    // are necessary params used when bridging tokens to L1.
    mapping(address => address) public whitelistedTokens;

    event ArbitrumTokensBridged(address indexed l1Token, address target, uint256 numberOfTokensBridged);
    event SetL2GatewayRouter(address indexed newL2GatewayRouter);
    event WhitelistedTokens(address indexed l2Token, address indexed l1Token);

    /**
     * @notice Construct the AVM SpokePool.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     * @param timerAddress Timer address to set.
     */
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {}

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /********************************************************
     *    ARBITRUM-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Add L2 -> L1 token mapping. Callable only by admin.
     * @param l2Token Arbitrum token.
     * @param l1Token Ethereum version of l2Token.
     */
    function whitelistToken(address l2Token, address l1Token) public onlyAdmin nonReentrant {
        _whitelistToken(l2Token, l1Token);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _whitelistToken(address _l2Token, address _l1Token) internal {
        whitelistedTokens[_l2Token] = _l1Token;
        emit WhitelistedTokens(_l2Token, _l1Token);
    }

    // L1 addresses are transformed during l1->l2 calls.
    // See https://developer.offchainlabs.com/docs/l1_l2_messages#address-aliasing for more information.
    // This cannot be pulled directly from Arbitrum contracts because their contracts are not 0.8.X compatible and
    // this operation takes advantage of overflows, whose behavior changed in 0.8.0.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        // Allows overflows as explained above.
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    // Apply AVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
