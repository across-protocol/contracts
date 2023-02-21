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

/**
 * @notice ZkSync specific SpokePool, intended to be compiled with `@matterlabs/hardhat-zksync-solc`.
 */
contract ZkSync_SpokePool is SpokePool {
    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.

    // However, this contract is expected to be deployed only once to ZkSync. Therefore, we should consider the cost
    // of reading mutable vs immutable storage. On Ethereum, mutable storage is more expensive than immutable bytecode.
    // But, we also want to be able to upgrade certain state variables.

    // Bridge used to withdraw ERC20's to L1: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ERC20Bridge.sol
    ZkBridgeLike public zkErc20Bridge;

    // Bridge used to send ETH to L1: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ETHBridge.sol
    ZkBridgeLike public zkEthBridge;

    event SetZkBridges(address indexed erc20Bridge, address indexed ethBridge);
    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    /**
     * @notice Construct the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _zkEthBridge Address of L2 ETH gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        ZkBridgeLike _zkEthBridge,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wethAddress);
        _setZkBridges(_zkErc20Bridge, _zkEthBridge);
    }

    modifier onlyFromCrossDomainAdmin() {
        // Formal msg.sender of L1 --> L2 message will be L1 sender.
        require(msg.sender == crossDomainAdmin, "Invalid sender");
        _;
    }

    /**
     * @notice Returns chain ID for this network.
     * @dev ZKSync doesn't yet support the CHAIN_ID opcode so we override this, but it will be supported by mainnet
     * launch supposedly: https://v2-docs.zksync.io/dev/zksync-v2/temp-limits.html#temporarily-simulated-by-constant-values
     */
    function chainId() public pure override returns (uint256) {
        return 280;
    }

    /********************************************************
     *      ZKSYNC-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change L2 token bridge addresses. Callable only by admin.
     * @param _zkErc20Bridge New address of L2 ERC20 gateway.
     * @param _zkEthBridge New address of L2 ETH gateway.
     */
    function setZkBridges(ZkBridgeLike _zkErc20Bridge, ZkBridgeLike _zkEthBridge) public onlyAdmin nonReentrant {
        _setZkBridges(_zkErc20Bridge, _zkEthBridge);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        (relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken) ? zkEthBridge : zkErc20Bridge).withdraw(
            hubPool,
            // Note: If ETH, must use 0x0: https://github.com/matter-labs/v2-testnet-contracts/blob/3a0651357bb685751c2163e4cc65a240b0f602ef/l2/contracts/bridge/L2ETHBridge.sol#L57
            relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken)
                ? address(0)
                : relayerRefundLeaf.l2TokenAddress,
            relayerRefundLeaf.amountToReturn
        );

        emit ZkSyncTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _setZkBridges(ZkBridgeLike _zkErc20Bridge, ZkBridgeLike _zkEthBridge) internal {
        zkErc20Bridge = _zkErc20Bridge;
        zkEthBridge = _zkEthBridge;
        emit SetZkBridges(address(_zkErc20Bridge), address(_zkEthBridge));
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
