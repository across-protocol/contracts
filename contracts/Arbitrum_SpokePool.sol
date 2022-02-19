//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

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

contract Arbitrum_SpokePool is SpokePoolInterface, SpokePool {
    // Address of the Arbitrum L2 token gateway.
    address public l2GatewayRouter;

    // Admin controlled mapping of arbitrum tokens to L1 counterpart. L1 counterpart addresses
    // are neccessary to bridge tokens to L1.
    mapping(address => address) public whitelistedTokens;

    event ArbitrumTokensBridged(address indexed l1Token, address target, uint256 numberOfTokensBridged);
    event SetL2GatewayRouter(address indexed newL2GatewayRouter);
    event WhitelistedTokens(address indexed l2Token, address indexed l1Token);

    constructor(
        address _l2GatewayRouter,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {
        _setL2GatewayRouter(_l2GatewayRouter);
    }

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /**************************************
     *    CROSS-CHAIN ADMIN FUNCTIONS     *
     **************************************/

    function setL2GatewayRouter(address newL2GatewayRouter) public onlyFromCrossDomainAdmin nonReentrant {
        _setL2GatewayRouter(newL2GatewayRouter);
    }

    function whitelistToken(address l2Token, address l1Token) public onlyFromCrossDomainAdmin nonReentrant {
        _whitelistToken(l2Token, l1Token);
    }

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyFromCrossDomainAdmin nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyFromCrossDomainAdmin nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public override onlyFromCrossDomainAdmin nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer) public override onlyFromCrossDomainAdmin nonReentrant {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayFulfillmentRoot)
        public
        override
        onlyFromCrossDomainAdmin
        nonReentrant
    {
        _relayRootBundle(relayerRefundRoot, slowRelayFulfillmentRoot);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _chainId() internal view override returns (uint256) {
        return block.chainid;
    }

    function _verifyDepositorUpdateFeeMessage(
        address depositor,
        bytes32 ethSignedMessageHash,
        bytes memory depositorSignature
    ) internal view override {
        _defaultVerifyDepositorUpdateFeeMessage(depositor, ethSignedMessageHash, depositorSignature);
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        StandardBridgeLike(l2GatewayRouter).outboundTransfer(
            whitelistedTokens[relayerRefundLeaf.l2TokenAddress], // _l1Token. Address of the L1 token to bridge over.
            hubPool, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
            relayerRefundLeaf.amountToReturn, // _amount.
            "" // _data. We don't need to send any data for the bridging action.
        );
        emit ArbitrumTokensBridged(address(0), hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _setL2GatewayRouter(address _l2GatewayRouter) internal {
        l2GatewayRouter = _l2GatewayRouter;
        emit SetL2GatewayRouter(l2GatewayRouter);
    }

    function _whitelistToken(address _l2Token, address _l1Token) internal {
        whitelistedTokens[_l2Token] = _l1Token;
        emit WhitelistedTokens(_l2Token, _l1Token);
    }

    // l1 addresses are transformed during l1->l2 calls. See https://developer.offchainlabs.com/docs/l1_l2_messages#address-aliasing for more information.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }
}
