// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";

interface ZkBridgeLike {
    function withdraw(
        address _to,
        address _l2Token,
        uint256 _amount
    ) external;
}

// This contract is intended to be compiled only with `@matterlabs/hardhat-zksync-solc`.
contract ZkSync_SpokePool is SpokePool {
    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.
    address public zkErc20Bridge;
    address public zkEthBridge;

    event SetZkBridges(address indexed erc20Bridge, address indexed ethBridge);
    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    constructor(
        address _zkErc20Bridge,
        address _zkEthBridge,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {
        _setZkBridges(_zkErc20Bridge, _zkEthBridge);
    }

    // TODO: Currently don't perform any checks as I don't know yet how cross domain checks work.
    modifier onlyFromCrossDomainAdmin() {
        // Will be some L1 contract, either the HubPool or some ZkSync intermediate contract. I'm surprised aliasing
        // isn't a thing due to issues without aliasing, see:
        // https://community.optimism.io/docs/developers/build/differences/#address-aliasing
        _;
    }

    /********************************************************
     *      ZKSYNC-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    function setZkBridges(address _zkErc20Bridge, address _zkEthBridge) public onlyAdmin nonReentrant {
        _setZkBridges(_zkErc20Bridge, _zkEthBridge);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        ZkBridgeLike(relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken) ? zkEthBridge : zkErc20Bridge)
            .withdraw(hubPool, relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);

        emit ZkSyncTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _setZkBridges(address _zkErc20Bridge, address _zkEthBridge) internal {
        zkErc20Bridge = _zkErc20Bridge;
        zkEthBridge = _zkEthBridge;
        emit SetZkBridges(_zkErc20Bridge, _zkEthBridge);
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
