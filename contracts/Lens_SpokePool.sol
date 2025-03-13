// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./ZkSync_SpokePool.sol";

/**
 * @notice Lens specific SpokePool. Wrapper around the ZkSync_SpokePool contract.
 * @dev Resources for compiling and deploying contracts with hardhat: https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html
 * @custom:security-contact bugs@across.to
 */
contract Lens_SpokePool is ZkSync_SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) ZkSync_SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks
}
