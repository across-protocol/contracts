// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";

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

    /**
     * @notice Construct the ZkSync SpokePool.
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

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
