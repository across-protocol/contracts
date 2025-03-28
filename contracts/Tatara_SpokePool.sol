// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { PolygonZkEVM_SpokePool } from "./PolygonZkEVM_SpokePool.sol";

/**
 * @notice Polygon zkEVM Spoke pool.
 * @custom:security-contact bugs@across.to
 */
contract Tatara_SpokePool is PolygonZkEVM_SpokePool {
    /**
     * @notice Construct Polygon zkEVM specific SpokePool.
     * @param _wrappedNativeTokenAddress Address of WETH on Polygon zkEVM.
     * @param _depositQuoteTimeBuffer Quote timestamps can't be set more than this amount
     * into the past from the block time of the deposit.
     * @param _fillDeadlineBuffer Fill deadlines can't be set more than this amount
     * into the future from the block time of the deposit.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) PolygonZkEVM_SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks
}
